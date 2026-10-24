/* #1758 R1.6a: final reader contract through the no-SDL amalgamation.
 * Raw nonfinite fixtures bypass constructors deliberately: the new readers
 * must refuse them before a C conversion. Every call borrows the same heap
 * boxed int/string control; reference counts are checked on success/raise. */
#include "eigenscript_all.c"

static int reader_checks, reader_failures, reader_calls;
static void check(int ok, const char *name) {
    reader_checks++;
    if (!ok) { printf("phase2-readers-test: FAIL %s\n", name); reader_failures++; }
}
static void reset_error(void) {
    eigs_clear_error_value(); g_has_error = 0; g_error_print_pending = 0;
    g_error_msg[0] = 0; g_error_raw[0] = 0;
}
static void checked_error(int want, const char *name) {
    check(!!g_has_error == !!want, name);
    if (want) check(g_error_kind == EK_VALUE && strstr(g_error_raw, "reader") != NULL, name);
}

/* Expectations are literals, independent of the readers' conversion code. */
typedef struct {
    const char *name; int is_int; int64_t i; double f;
    int finite, exact; int64_t integer;
    int magnitude_ok; int64_t magnitude;
    int bounded;
} ReaderCase;
static const ReaderCase reader_cases[] = {
    {"zero", 1, 0, 0, 1, 1, 0, 1, 0, 0},
    {"minus-one", 1, -1, 0, 1, 1, -1, 1, -1, 0},
    {"byte-max", 1, 255, 0, 1, 1, 255, 1, 255, 255},
    {"above-byte", 1, 256, 0, 1, 1, 256, 1, 256, 255},
    {"bounded-clamp", 1, 300, 0, 1, 1, 300, 1, 300, 255},
    {"two53-plus1-int", 1, INT64_C(9007199254740993), 0, 1, 1, INT64_C(9007199254740993), 1, INT64_C(9007199254740993), 255},
    {"int64-min", 1, INT64_MIN, 0, 1, 1, INT64_MIN, 1, INT64_MIN, 0},
    {"int64-max", 1, INT64_MAX, 0, 1, 1, INT64_MAX, 1, INT64_MAX, 255},
    {"integral-float", 0, 0, 42.0, 1, 1, 42, 1, 42, 42},
    {"fraction", 0, 0, 1.5, 1, 0, 0, 1, 2, 2},
    {"negative-half", 0, 0, -1.5, 1, 0, 0, 1, -2, 0},
    {"two53-plus1-float", 0, 0, 9007199254740993.0, 1, 1, INT64_C(9007199254740992), 1, INT64_C(9007199254740992), 255},
    {"float-int64-min", 0, 0, -9223372036854775808.0, 1, 1, INT64_MIN, 1, INT64_MIN, 0},
    {"float-int64-upper-inside", 0, 0, 9223372036854774784.0, 1, 1, INT64_C(9223372036854774784), 1, INT64_C(9223372036854774784), 255},
    {"float-int64-upper", 0, 0, 9223372036854775808.0, 1, 0, 0, 0, 0, 255},
    {"below-int64-min", 0, 0, -9223372036854777856.0, 1, 0, 0, 0, 0, 0},
    {"nan", 0, 0, NAN, 0, 0, 0, 0, 0, 0},
    {"inf", 0, 0, INFINITY, 0, 0, 0, 0, 0, 0},
    {"minus-inf", 0, 0, -INFINITY, 0, 0, 0, 0, 0, 0},
};

static void exercise_case(const ReaderCase *c) {
    Value fv = { .type = VAL_FLOAT };
    VAL_F64_RAW(&fv) = c->f;
    Value *v = c->is_int ? make_int(c->i) : &fv;
    EigsSlot slot = c->is_int ? (c->i >= SLOT_SMI_MIN && c->i <= SLOT_SMI_MAX ? slot_from_int(c->i) : slot_from_heap(v)) : slot_from_f64(c->f);
    Value *list = make_list_heap(1);
    /* A borrowed raw fixture must retain a boxed int for the list. This also
     * lets hostile buffer/scalar doubles reach each reader without num_guard. */
    list_values_storage(list)[0] = slot_read_owned(slot);
    list->data.list.count = 1;
    int refs = v->refcount;
    const char *who = "builtin_reader";
    {
        reset_error(); reader_calls++;
        int want_error = !c->finite;
        EigsNum out = eigs_number_arg(v, who);
        checked_error(want_error, "eigs_number_arg");
        check(want_error || (out.is_int == c->is_int && (c->is_int ? out.value.i64 == c->i : out.value.f64 == c->f)), "eigs_number_arg result");
        check(v->refcount == refs, "eigs_number_arg borrowed ownership");
    }
    {
        reset_error(); reader_calls++;
        int want_error = !c->finite;
        EigsNum out = eigs_list_number(list, 0, who);
        checked_error(want_error, "eigs_list_number");
        check(want_error || (out.is_int == c->is_int && (c->is_int ? out.value.i64 == c->i : out.value.f64 == c->f)), "eigs_list_number result");
        check(v->refcount == refs, "eigs_list_number borrowed ownership");
    }
    {
        reset_error(); reader_calls++;
        int want_error = !c->finite;
        EigsNum out = eigs_elem_number(v, who);
        checked_error(want_error, "eigs_elem_number");
        check(want_error || (out.is_int == c->is_int && (c->is_int ? out.value.i64 == c->i : out.value.f64 == c->f)), "eigs_elem_number result");
        check(v->refcount == refs, "eigs_elem_number borrowed ownership");
    }
    {
        reset_error(); reader_calls++;
        int want_error = !c->finite;
        EigsNum out = (EigsNum){ .is_int = 1, .value = { .i64 = -73 } };
        int rc = eigs_opt_number(v, &out, who);
        check(rc == !want_error, "eigs_opt_number status");
        check(!want_error || (out.is_int && out.value.i64 == -73), "eigs_opt_number refusal preserves output");
        checked_error(want_error, "eigs_opt_number");
        check(want_error || (out.is_int == c->is_int && (c->is_int ? out.value.i64 == c->i : out.value.f64 == c->f)), "eigs_opt_number result");
        check(v->refcount == refs, "eigs_opt_number borrowed ownership");
    }
    {
        reset_error(); reader_calls++;
        int want_error = !c->finite;
        EigsNum out = eigs_slot_number(slot, who);
        checked_error(want_error, "eigs_slot_number");
        check(want_error || (out.is_int == c->is_int && (c->is_int ? out.value.i64 == c->i : out.value.f64 == c->f)), "eigs_slot_number result");
        check(v->refcount == refs, "eigs_slot_number borrowed ownership");
    }
    {
        reset_error(); reader_calls++;
        int want_error = !c->finite;
        EigsNum out = eigs_slot_elem_number(slot, who);
        checked_error(want_error, "eigs_slot_elem_number");
        check(want_error || (out.is_int == c->is_int && (c->is_int ? out.value.i64 == c->i : out.value.f64 == c->f)), "eigs_slot_elem_number result");
        check(v->refcount == refs, "eigs_slot_elem_number borrowed ownership");
    }
    {
        reset_error(); reader_calls++;
        int want_error = !c->finite;
        EigsNum out = (EigsNum){ .is_int = 1, .value = { .i64 = -73 } };
        int rc = eigs_slot_opt_number(slot, &out, who);
        check(rc == !want_error, "eigs_slot_opt_number status");
        check(!want_error || (out.is_int && out.value.i64 == -73), "eigs_slot_opt_number refusal preserves output");
        checked_error(want_error, "eigs_slot_opt_number");
        check(want_error || (out.is_int == c->is_int && (c->is_int ? out.value.i64 == c->i : out.value.f64 == c->f)), "eigs_slot_opt_number result");
        check(v->refcount == refs, "eigs_slot_opt_number borrowed ownership");
    }
    {
        reset_error(); reader_calls++;
        int want_error = !c->finite;
        double out = eigs_float_arg(v, who);
        checked_error(want_error, "eigs_float_arg");
        check(want_error || (out == (c->is_int ? (double)c->i : c->f)), "eigs_float_arg result");
        check(v->refcount == refs, "eigs_float_arg borrowed ownership");
    }
    {
        reset_error(); reader_calls++;
        int want_error = !c->finite;
        double out = eigs_list_float(list, 0, who);
        checked_error(want_error, "eigs_list_float");
        check(want_error || (out == (c->is_int ? (double)c->i : c->f)), "eigs_list_float result");
        check(v->refcount == refs, "eigs_list_float borrowed ownership");
    }
    {
        reset_error(); reader_calls++;
        int want_error = !c->finite;
        double out = eigs_elem_float(v, who);
        checked_error(want_error, "eigs_elem_float");
        check(want_error || (out == (c->is_int ? (double)c->i : c->f)), "eigs_elem_float result");
        check(v->refcount == refs, "eigs_elem_float borrowed ownership");
    }
    {
        reset_error(); reader_calls++;
        int want_error = !c->finite;
        double out = -73;
        int rc = eigs_opt_float(v, &out, who);
        check(rc == !want_error, "eigs_opt_float status");
        check(!want_error || (out == -73), "eigs_opt_float refusal preserves output");
        checked_error(want_error, "eigs_opt_float");
        check(want_error || (out == (c->is_int ? (double)c->i : c->f)), "eigs_opt_float result");
        check(v->refcount == refs, "eigs_opt_float borrowed ownership");
    }
    {
        reset_error(); reader_calls++;
        int want_error = !c->finite;
        double out = eigs_slot_float(slot, who);
        checked_error(want_error, "eigs_slot_float");
        check(want_error || (out == (c->is_int ? (double)c->i : c->f)), "eigs_slot_float result");
        check(v->refcount == refs, "eigs_slot_float borrowed ownership");
    }
    {
        reset_error(); reader_calls++;
        int want_error = !c->finite;
        double out = eigs_slot_elem_float(slot, who);
        checked_error(want_error, "eigs_slot_elem_float");
        check(want_error || (out == (c->is_int ? (double)c->i : c->f)), "eigs_slot_elem_float result");
        check(v->refcount == refs, "eigs_slot_elem_float borrowed ownership");
    }
    {
        reset_error(); reader_calls++;
        int want_error = !c->finite;
        double out = -73;
        int rc = eigs_slot_opt_float(slot, &out, who);
        check(rc == !want_error, "eigs_slot_opt_float status");
        check(!want_error || (out == -73), "eigs_slot_opt_float refusal preserves output");
        checked_error(want_error, "eigs_slot_opt_float");
        check(want_error || (out == (c->is_int ? (double)c->i : c->f)), "eigs_slot_opt_float result");
        check(v->refcount == refs, "eigs_slot_opt_float borrowed ownership");
    }
    {
        reset_error(); reader_calls++;
        int want_error = !c->exact;
        int64_t out = eigs_int_arg(v, who);
        checked_error(want_error, "eigs_int_arg");
        check(want_error || (out == c->integer), "eigs_int_arg result");
        check(v->refcount == refs, "eigs_int_arg borrowed ownership");
    }
    {
        reset_error(); reader_calls++;
        int want_error = !c->exact;
        int64_t out = eigs_list_int(list, 0, who);
        checked_error(want_error, "eigs_list_int");
        check(want_error || (out == c->integer), "eigs_list_int result");
        check(v->refcount == refs, "eigs_list_int borrowed ownership");
    }
    {
        reset_error(); reader_calls++;
        int want_error = !c->exact;
        int64_t out = eigs_elem_int(v, who);
        checked_error(want_error, "eigs_elem_int");
        check(want_error || (out == c->integer), "eigs_elem_int result");
        check(v->refcount == refs, "eigs_elem_int borrowed ownership");
    }
    {
        reset_error(); reader_calls++;
        int want_error = !c->exact;
        int64_t out = -73;
        int rc = eigs_opt_int(v, &out, who);
        check(rc == !want_error, "eigs_opt_int status");
        check(!want_error || (out == -73), "eigs_opt_int refusal preserves output");
        checked_error(want_error, "eigs_opt_int");
        check(want_error || (out == c->integer), "eigs_opt_int result");
        check(v->refcount == refs, "eigs_opt_int borrowed ownership");
    }
    {
        reset_error(); reader_calls++;
        int want_error = !c->exact;
        int64_t out = eigs_slot_int(slot, who);
        checked_error(want_error, "eigs_slot_int");
        check(want_error || (out == c->integer), "eigs_slot_int result");
        check(v->refcount == refs, "eigs_slot_int borrowed ownership");
    }
    {
        reset_error(); reader_calls++;
        int want_error = !c->exact;
        int64_t out = eigs_slot_elem_int(slot, who);
        checked_error(want_error, "eigs_slot_elem_int");
        check(want_error || (out == c->integer), "eigs_slot_elem_int result");
        check(v->refcount == refs, "eigs_slot_elem_int borrowed ownership");
    }
    {
        reset_error(); reader_calls++;
        int want_error = !c->exact;
        int64_t out = -73;
        int rc = eigs_slot_opt_int(slot, &out, who);
        check(rc == !want_error, "eigs_slot_opt_int status");
        check(!want_error || (out == -73), "eigs_slot_opt_int refusal preserves output");
        checked_error(want_error, "eigs_slot_opt_int");
        check(want_error || (out == c->integer), "eigs_slot_opt_int result");
        check(v->refcount == refs, "eigs_slot_opt_int borrowed ownership");
    }
    {
        reset_error(); reader_calls++;
        int want_error = !c->exact || c->integer < 0 || c->integer > 255;
        uint8_t out = eigs_byte_arg(v, who);
        checked_error(want_error, "eigs_byte_arg");
        check(want_error || (out == c->integer), "eigs_byte_arg result");
        check(v->refcount == refs, "eigs_byte_arg borrowed ownership");
    }
    {
        reset_error(); reader_calls++;
        int want_error = !c->exact || c->integer < 0 || c->integer > 255;
        uint8_t out = eigs_list_byte(list, 0, who);
        checked_error(want_error, "eigs_list_byte");
        check(want_error || (out == c->integer), "eigs_list_byte result");
        check(v->refcount == refs, "eigs_list_byte borrowed ownership");
    }
    {
        reset_error(); reader_calls++;
        int want_error = !c->exact || c->integer < 0 || c->integer > 255;
        uint8_t out = eigs_elem_byte(v, who);
        checked_error(want_error, "eigs_elem_byte");
        check(want_error || (out == c->integer), "eigs_elem_byte result");
        check(v->refcount == refs, "eigs_elem_byte borrowed ownership");
    }
    {
        reset_error(); reader_calls++;
        int want_error = !c->exact || c->integer < 0 || c->integer > 255;
        uint8_t out = 73;
        int rc = eigs_opt_byte(v, &out, who);
        check(rc == !want_error, "eigs_opt_byte status");
        check(!want_error || (out == 73), "eigs_opt_byte refusal preserves output");
        checked_error(want_error, "eigs_opt_byte");
        check(want_error || (out == c->integer), "eigs_opt_byte result");
        check(v->refcount == refs, "eigs_opt_byte borrowed ownership");
    }
    {
        reset_error(); reader_calls++;
        int want_error = !c->exact || c->integer < 0 || c->integer > 255;
        uint8_t out = eigs_slot_byte(slot, who);
        checked_error(want_error, "eigs_slot_byte");
        check(want_error || (out == c->integer), "eigs_slot_byte result");
        check(v->refcount == refs, "eigs_slot_byte borrowed ownership");
    }
    {
        reset_error(); reader_calls++;
        int want_error = !c->exact || c->integer < 0 || c->integer > 255;
        uint8_t out = eigs_slot_elem_byte(slot, who);
        checked_error(want_error, "eigs_slot_elem_byte");
        check(want_error || (out == c->integer), "eigs_slot_elem_byte result");
        check(v->refcount == refs, "eigs_slot_elem_byte borrowed ownership");
    }
    {
        reset_error(); reader_calls++;
        int want_error = !c->exact || c->integer < 0 || c->integer > 255;
        uint8_t out = 73;
        int rc = eigs_slot_opt_byte(slot, &out, who);
        check(rc == !want_error, "eigs_slot_opt_byte status");
        check(!want_error || (out == 73), "eigs_slot_opt_byte refusal preserves output");
        checked_error(want_error, "eigs_slot_opt_byte");
        check(want_error || (out == c->integer), "eigs_slot_opt_byte result");
        check(v->refcount == refs, "eigs_slot_opt_byte borrowed ownership");
    }
    {
        reset_error(); reader_calls++;
        int want_error = !c->exact;
        int64_t out = -73;
        int rc = eigs_int_arg_range(v, INT64_MIN, INT64_MAX, &out, who);
        check(rc == !want_error, "eigs_int_arg_range status");
        check(!want_error || (out == -73), "eigs_int_arg_range refusal preserves output");
        checked_error(want_error, "eigs_int_arg_range");
        check(want_error || (out == c->integer), "eigs_int_arg_range result");
        check(v->refcount == refs, "eigs_int_arg_range borrowed ownership");
    }
    {
        reset_error(); reader_calls++;
        int want_error = !c->exact;
        int64_t out = -73;
        int rc = eigs_list_int_range(list, 0, INT64_MIN, INT64_MAX, &out, who);
        check(rc == !want_error, "eigs_list_int_range status");
        check(!want_error || (out == -73), "eigs_list_int_range refusal preserves output");
        checked_error(want_error, "eigs_list_int_range");
        check(want_error || (out == c->integer), "eigs_list_int_range result");
        check(v->refcount == refs, "eigs_list_int_range borrowed ownership");
    }
    {
        reset_error(); reader_calls++;
        int want_error = !c->exact;
        int64_t out = -73;
        int rc = eigs_elem_int_range(v, INT64_MIN, INT64_MAX, &out, who);
        check(rc == !want_error, "eigs_elem_int_range status");
        check(!want_error || (out == -73), "eigs_elem_int_range refusal preserves output");
        checked_error(want_error, "eigs_elem_int_range");
        check(want_error || (out == c->integer), "eigs_elem_int_range result");
        check(v->refcount == refs, "eigs_elem_int_range borrowed ownership");
    }
    {
        reset_error(); reader_calls++;
        int want_error = !c->exact;
        int64_t out = -73;
        int rc = eigs_opt_int_range(v, INT64_MIN, INT64_MAX, &out, who);
        check(rc == !want_error, "eigs_opt_int_range status");
        check(!want_error || (out == -73), "eigs_opt_int_range refusal preserves output");
        checked_error(want_error, "eigs_opt_int_range");
        check(want_error || (out == c->integer), "eigs_opt_int_range result");
        check(v->refcount == refs, "eigs_opt_int_range borrowed ownership");
    }
    {
        reset_error(); reader_calls++;
        int want_error = !c->exact;
        int64_t out = -73;
        int rc = eigs_slot_int_range(slot, INT64_MIN, INT64_MAX, &out, who);
        check(rc == !want_error, "eigs_slot_int_range status");
        check(!want_error || (out == -73), "eigs_slot_int_range refusal preserves output");
        checked_error(want_error, "eigs_slot_int_range");
        check(want_error || (out == c->integer), "eigs_slot_int_range result");
        check(v->refcount == refs, "eigs_slot_int_range borrowed ownership");
    }
    {
        reset_error(); reader_calls++;
        int want_error = !c->exact;
        int64_t out = -73;
        int rc = eigs_slot_elem_int_range(slot, INT64_MIN, INT64_MAX, &out, who);
        check(rc == !want_error, "eigs_slot_elem_int_range status");
        check(!want_error || (out == -73), "eigs_slot_elem_int_range refusal preserves output");
        checked_error(want_error, "eigs_slot_elem_int_range");
        check(want_error || (out == c->integer), "eigs_slot_elem_int_range result");
        check(v->refcount == refs, "eigs_slot_elem_int_range borrowed ownership");
    }
    {
        reset_error(); reader_calls++;
        int want_error = !c->exact;
        int64_t out = -73;
        int rc = eigs_slot_opt_int_range(slot, INT64_MIN, INT64_MAX, &out, who);
        check(rc == !want_error, "eigs_slot_opt_int_range status");
        check(!want_error || (out == -73), "eigs_slot_opt_int_range refusal preserves output");
        checked_error(want_error, "eigs_slot_opt_int_range");
        check(want_error || (out == c->integer), "eigs_slot_opt_int_range result");
        check(v->refcount == refs, "eigs_slot_opt_int_range borrowed ownership");
    }
    {
        reset_error(); reader_calls++;
        int want_error = !c->finite;
        int out = -73;
        int rc = eigs_bounded_arg(v, 0, 255, &out, who);
        check(rc == !want_error, "eigs_bounded_arg status");
        check(!want_error || (out == -73), "eigs_bounded_arg refusal preserves output");
        checked_error(want_error, "eigs_bounded_arg");
        check(want_error || (out == c->bounded), "eigs_bounded_arg result");
        check(v->refcount == refs, "eigs_bounded_arg borrowed ownership");
    }
    {
        reset_error(); reader_calls++;
        int want_error = !c->finite;
        int out = -73;
        int rc = eigs_list_bounded(list, 0, 0, 255, &out, who);
        check(rc == !want_error, "eigs_list_bounded status");
        check(!want_error || (out == -73), "eigs_list_bounded refusal preserves output");
        checked_error(want_error, "eigs_list_bounded");
        check(want_error || (out == c->bounded), "eigs_list_bounded result");
        check(v->refcount == refs, "eigs_list_bounded borrowed ownership");
    }
    {
        reset_error(); reader_calls++;
        int want_error = !c->finite;
        int out = -73;
        int rc = eigs_elem_bounded(v, 0, 255, &out, who);
        check(rc == !want_error, "eigs_elem_bounded status");
        check(!want_error || (out == -73), "eigs_elem_bounded refusal preserves output");
        checked_error(want_error, "eigs_elem_bounded");
        check(want_error || (out == c->bounded), "eigs_elem_bounded result");
        check(v->refcount == refs, "eigs_elem_bounded borrowed ownership");
    }
    {
        reset_error(); reader_calls++;
        int want_error = !c->finite;
        int out = -73;
        int rc = eigs_opt_bounded(v, 0, 255, &out, who);
        check(rc == !want_error, "eigs_opt_bounded status");
        check(!want_error || (out == -73), "eigs_opt_bounded refusal preserves output");
        checked_error(want_error, "eigs_opt_bounded");
        check(want_error || (out == c->bounded), "eigs_opt_bounded result");
        check(v->refcount == refs, "eigs_opt_bounded borrowed ownership");
    }
    {
        reset_error(); reader_calls++;
        int want_error = !c->finite;
        int out = -73;
        int rc = eigs_slot_bounded(slot, 0, 255, &out, who);
        check(rc == !want_error, "eigs_slot_bounded status");
        check(!want_error || (out == -73), "eigs_slot_bounded refusal preserves output");
        checked_error(want_error, "eigs_slot_bounded");
        check(want_error || (out == c->bounded), "eigs_slot_bounded result");
        check(v->refcount == refs, "eigs_slot_bounded borrowed ownership");
    }
    {
        reset_error(); reader_calls++;
        int want_error = !c->finite;
        int out = -73;
        int rc = eigs_slot_elem_bounded(slot, 0, 255, &out, who);
        check(rc == !want_error, "eigs_slot_elem_bounded status");
        check(!want_error || (out == -73), "eigs_slot_elem_bounded refusal preserves output");
        checked_error(want_error, "eigs_slot_elem_bounded");
        check(want_error || (out == c->bounded), "eigs_slot_elem_bounded result");
        check(v->refcount == refs, "eigs_slot_elem_bounded borrowed ownership");
    }
    {
        reset_error(); reader_calls++;
        int want_error = !c->finite;
        int out = -73;
        int rc = eigs_slot_opt_bounded(slot, 0, 255, &out, who);
        check(rc == !want_error, "eigs_slot_opt_bounded status");
        check(!want_error || (out == -73), "eigs_slot_opt_bounded refusal preserves output");
        checked_error(want_error, "eigs_slot_opt_bounded");
        check(want_error || (out == c->bounded), "eigs_slot_opt_bounded result");
        check(v->refcount == refs, "eigs_slot_opt_bounded borrowed ownership");
    }
    {
        reset_error(); reader_calls++;
        int want_error = !c->magnitude_ok;
        int64_t out = -73;
        int rc = eigs_magnitude_arg(v, INT64_MIN, INT64_MAX, &out, who);
        check(rc == !want_error, "eigs_magnitude_arg status");
        check(!want_error || (out == -73), "eigs_magnitude_arg refusal preserves output");
        checked_error(want_error, "eigs_magnitude_arg");
        check(want_error || (out == c->magnitude), "eigs_magnitude_arg result");
        check(v->refcount == refs, "eigs_magnitude_arg borrowed ownership");
    }
    {
        reset_error(); reader_calls++;
        int want_error = !c->magnitude_ok;
        int64_t out = -73;
        int rc = eigs_list_magnitude(list, 0, INT64_MIN, INT64_MAX, &out, who);
        check(rc == !want_error, "eigs_list_magnitude status");
        check(!want_error || (out == -73), "eigs_list_magnitude refusal preserves output");
        checked_error(want_error, "eigs_list_magnitude");
        check(want_error || (out == c->magnitude), "eigs_list_magnitude result");
        check(v->refcount == refs, "eigs_list_magnitude borrowed ownership");
    }
    {
        reset_error(); reader_calls++;
        int want_error = !c->magnitude_ok;
        int64_t out = -73;
        int rc = eigs_elem_magnitude(v, INT64_MIN, INT64_MAX, &out, who);
        check(rc == !want_error, "eigs_elem_magnitude status");
        check(!want_error || (out == -73), "eigs_elem_magnitude refusal preserves output");
        checked_error(want_error, "eigs_elem_magnitude");
        check(want_error || (out == c->magnitude), "eigs_elem_magnitude result");
        check(v->refcount == refs, "eigs_elem_magnitude borrowed ownership");
    }
    {
        reset_error(); reader_calls++;
        int want_error = !c->magnitude_ok;
        int64_t out = -73;
        int rc = eigs_opt_magnitude(v, INT64_MIN, INT64_MAX, &out, who);
        check(rc == !want_error, "eigs_opt_magnitude status");
        check(!want_error || (out == -73), "eigs_opt_magnitude refusal preserves output");
        checked_error(want_error, "eigs_opt_magnitude");
        check(want_error || (out == c->magnitude), "eigs_opt_magnitude result");
        check(v->refcount == refs, "eigs_opt_magnitude borrowed ownership");
    }
    {
        reset_error(); reader_calls++;
        int want_error = !c->magnitude_ok;
        int64_t out = -73;
        int rc = eigs_slot_magnitude(slot, INT64_MIN, INT64_MAX, &out, who);
        check(rc == !want_error, "eigs_slot_magnitude status");
        check(!want_error || (out == -73), "eigs_slot_magnitude refusal preserves output");
        checked_error(want_error, "eigs_slot_magnitude");
        check(want_error || (out == c->magnitude), "eigs_slot_magnitude result");
        check(v->refcount == refs, "eigs_slot_magnitude borrowed ownership");
    }
    {
        reset_error(); reader_calls++;
        int want_error = !c->magnitude_ok;
        int64_t out = -73;
        int rc = eigs_slot_elem_magnitude(slot, INT64_MIN, INT64_MAX, &out, who);
        check(rc == !want_error, "eigs_slot_elem_magnitude status");
        check(!want_error || (out == -73), "eigs_slot_elem_magnitude refusal preserves output");
        checked_error(want_error, "eigs_slot_elem_magnitude");
        check(want_error || (out == c->magnitude), "eigs_slot_elem_magnitude result");
        check(v->refcount == refs, "eigs_slot_elem_magnitude borrowed ownership");
    }
    {
        reset_error(); reader_calls++;
        int want_error = !c->magnitude_ok;
        int64_t out = -73;
        int rc = eigs_slot_opt_magnitude(slot, INT64_MIN, INT64_MAX, &out, who);
        check(rc == !want_error, "eigs_slot_opt_magnitude status");
        check(!want_error || (out == -73), "eigs_slot_opt_magnitude refusal preserves output");
        checked_error(want_error, "eigs_slot_opt_magnitude");
        check(want_error || (out == c->magnitude), "eigs_slot_opt_magnitude result");
        check(v->refcount == refs, "eigs_slot_opt_magnitude borrowed ownership");
    }
    reset_error();
    val_decref(list);
    if (c->is_int) val_decref(v);
}

static void boundaries(void) {
    int64_t out = -73;
    int bounded = -73;
    Value v = { .type = VAL_FLOAT };
    const int64_t xs[] = { -11, -10, 10, 11 };
    for (unsigned k = 0; k < sizeof xs / sizeof xs[0]; k++) {
        Value *i = make_int(xs[k]);
        reset_error(); int rc = eigs_int_arg_range(i, -10, 10, &out, "reader");
        check(rc == (k == 1 || k == 2), "int range inclusive boundaries");
        check(!rc || out == xs[k], "int range boundary result");
        reset_error(); rc = eigs_magnitude_arg(i, -10, 10, &out, "reader");
        check(rc == (k == 1 || k == 2), "magnitude inclusive boundaries");
        val_decref(i);
    }
    /* The C int edge is a separate range from int64: both edges succeed,
     * their adjacent integers refuse exact/magnitude conversion, and bounded
     * conversion clamps them before rounding. Expected values are literals. */
    static const struct {
        double input; int in_range; int expected;
    } c_int_edges[] = {
        { -2147483649.0, 0, INT_MIN },
        { -2147483648.0, 1, INT_MIN },
        { 2147483647.0, 1, INT_MAX },
        { 2147483648.0, 0, INT_MAX },
    };
    for (unsigned k = 0; k < sizeof c_int_edges / sizeof c_int_edges[0]; k++) {
        VAL_F64_RAW(&v) = c_int_edges[k].input;
        reset_error(); out = -73;
        int rc = eigs_int_arg_range(&v, INT_MIN, INT_MAX, &out, "reader");
        check(rc == c_int_edges[k].in_range, "C int exact inclusive boundary");
        check(rc ? out == c_int_edges[k].expected : out == -73,
              "C int exact boundary output");
        checked_error(!c_int_edges[k].in_range, "C int exact boundary error");
        reset_error(); out = -73;
        rc = eigs_magnitude_arg(&v, INT_MIN, INT_MAX, &out, "reader");
        check(rc == c_int_edges[k].in_range, "C int magnitude inclusive boundary");
        check(rc ? out == c_int_edges[k].expected : out == -73,
              "C int magnitude boundary output");
        checked_error(!c_int_edges[k].in_range, "C int magnitude boundary error");
        reset_error(); bounded = -73;
        check(eigs_bounded_arg(&v, INT_MIN, INT_MAX, &bounded, "reader") &&
              bounded == c_int_edges[k].expected && !g_has_error,
              "C int bounded edges clamp");
    }
    VAL_F64_RAW(&v) = 1.5;
    reset_error(); (void)eigs_int_arg(&v, "builtin_reader");
    check(g_has_error && strcmp(g_error_raw, "'reader': number 1.5 has no integer representation") == 0,
          "N5 reuses EIGS_NO_INT_REP_FMT");
    VAL_F64_RAW(&v) = 3e12;
    reset_error();
    check(!eigs_magnitude_arg(&v, INT_MIN, INT_MAX, &out, "reader") && g_error_kind == EK_VALUE,
          "magnitude 3e12 refuses C int range");
    VAL_F64_RAW(&v) = 10.49;
    reset_error(); check(eigs_magnitude_arg(&v, -10, 10, &out, "reader") && out == 10,
                         "magnitude rounds before range");
    VAL_F64_RAW(&v) = 10.5;
    reset_error(); check(!eigs_magnitude_arg(&v, -10, 10, &out, "reader"), "magnitude rounded above range");
    VAL_F64_RAW(&v) = -0.5;
    reset_error(); check(eigs_bounded_arg(&v, -255, 255, &bounded, "reader") && bounded == -1,
                         "bounded negative half away");
    reset_error(); check(!eigs_bounded_arg(&v, NAN, 255, &bounded, "reader"), "bounded invalid domain");
    reset_error(); check(!eigs_int_arg_range(&v, 10, -10, &out, "reader"), "inverted int range");
    reset_error(); check(!eigs_magnitude_arg(&v, 10, -10, &out, "reader"), "inverted magnitude range");
    reset_error();
}

static void optional_and_types(void) {
    Value *bad = make_str("heap-type-control");
    const char *who = "reader";
    int refs = bad->refcount;
    {
        EigsNum out = (EigsNum){ .is_int = 1, .value = { .i64 = 73 } };
        reset_error();
        check(!eigs_opt_number(NULL, &out, who) && !g_has_error && (out.is_int && out.value.i64 == 73), "eigs_opt_number absent");
        check(!eigs_opt_number(make_null(), &out, who) && !g_has_error && (out.is_int && out.value.i64 == 73), "eigs_opt_number null");
        check(!eigs_slot_opt_number(slot_null(), &out, who) && !g_has_error && (out.is_int && out.value.i64 == 73), "eigs_slot_opt_number null");
        reset_error();
        check(!eigs_opt_number(bad, &out, who) && g_has_error && g_error_kind == EK_TYPE && (out.is_int && out.value.i64 == 73), "eigs_opt_number wrong type");
        g_strict = 0; reset_error();
        out = eigs_elem_number(bad, who); check((out.is_int == 0 && out.value.f64 == 0) && !g_has_error, "eigs_elem_number non-strict zero");
        reset_error(); (void)eigs_elem_number(make_bool(1), who); check(g_has_error && g_error_kind == EK_TYPE, "eigs_elem_number bool always refuses");
        g_strict = 1; reset_error(); (void)eigs_elem_number(bad, who); check(g_has_error && g_error_kind == EK_TYPE, "eigs_elem_number strict wrong type");
        reset_error(); (void)eigs_list_number(NULL, 0, who); check(g_has_error && g_error_kind == EK_TYPE, "eigs_list_number missing argument");
        check(bad->refcount == refs, "number heap refusal ownership");
    }
    {
        double out = 73;
        reset_error();
        check(!eigs_opt_float(NULL, &out, who) && !g_has_error && (out == 73), "eigs_opt_float absent");
        check(!eigs_opt_float(make_null(), &out, who) && !g_has_error && (out == 73), "eigs_opt_float null");
        check(!eigs_slot_opt_float(slot_null(), &out, who) && !g_has_error && (out == 73), "eigs_slot_opt_float null");
        reset_error();
        check(!eigs_opt_float(bad, &out, who) && g_has_error && g_error_kind == EK_TYPE && (out == 73), "eigs_opt_float wrong type");
        g_strict = 0; reset_error();
        out = eigs_elem_float(bad, who); check((out == 0) && !g_has_error, "eigs_elem_float non-strict zero");
        reset_error(); (void)eigs_elem_float(make_bool(1), who); check(g_has_error && g_error_kind == EK_TYPE, "eigs_elem_float bool always refuses");
        g_strict = 1; reset_error(); (void)eigs_elem_float(bad, who); check(g_has_error && g_error_kind == EK_TYPE, "eigs_elem_float strict wrong type");
        reset_error(); (void)eigs_list_float(NULL, 0, who); check(g_has_error && g_error_kind == EK_TYPE, "eigs_list_float missing argument");
        check(bad->refcount == refs, "float heap refusal ownership");
    }
    {
        int64_t out = 73;
        reset_error();
        check(!eigs_opt_int(NULL, &out, who) && !g_has_error && (out == 73), "eigs_opt_int absent");
        check(!eigs_opt_int(make_null(), &out, who) && !g_has_error && (out == 73), "eigs_opt_int null");
        check(!eigs_slot_opt_int(slot_null(), &out, who) && !g_has_error && (out == 73), "eigs_slot_opt_int null");
        reset_error();
        check(!eigs_opt_int(bad, &out, who) && g_has_error && g_error_kind == EK_TYPE && (out == 73), "eigs_opt_int wrong type");
        g_strict = 0; reset_error();
        out = eigs_elem_int(bad, who); check((out == 0) && !g_has_error, "eigs_elem_int non-strict zero");
        reset_error(); (void)eigs_elem_int(make_bool(1), who); check(g_has_error && g_error_kind == EK_TYPE, "eigs_elem_int bool always refuses");
        g_strict = 1; reset_error(); (void)eigs_elem_int(bad, who); check(g_has_error && g_error_kind == EK_TYPE, "eigs_elem_int strict wrong type");
        reset_error(); (void)eigs_list_int(NULL, 0, who); check(g_has_error && g_error_kind == EK_TYPE, "eigs_list_int missing argument");
        check(bad->refcount == refs, "int heap refusal ownership");
    }
    {
        uint8_t out = 73;
        reset_error();
        check(!eigs_opt_byte(NULL, &out, who) && !g_has_error && (out == 73), "eigs_opt_byte absent");
        check(!eigs_opt_byte(make_null(), &out, who) && !g_has_error && (out == 73), "eigs_opt_byte null");
        check(!eigs_slot_opt_byte(slot_null(), &out, who) && !g_has_error && (out == 73), "eigs_slot_opt_byte null");
        reset_error();
        check(!eigs_opt_byte(bad, &out, who) && g_has_error && g_error_kind == EK_TYPE && (out == 73), "eigs_opt_byte wrong type");
        g_strict = 0; reset_error();
        out = eigs_elem_byte(bad, who); check((out == 0) && !g_has_error, "eigs_elem_byte non-strict zero");
        reset_error(); (void)eigs_elem_byte(make_bool(1), who); check(g_has_error && g_error_kind == EK_TYPE, "eigs_elem_byte bool always refuses");
        g_strict = 1; reset_error(); (void)eigs_elem_byte(bad, who); check(g_has_error && g_error_kind == EK_TYPE, "eigs_elem_byte strict wrong type");
        reset_error(); (void)eigs_list_byte(NULL, 0, who); check(g_has_error && g_error_kind == EK_TYPE, "eigs_list_byte missing argument");
        check(bad->refcount == refs, "byte heap refusal ownership");
    }
    {
        int64_t out = 73;
        reset_error();
        check(!eigs_opt_int_range(NULL, -10, 10, &out, who) && !g_has_error && (out == 73), "eigs_opt_int_range absent");
        check(!eigs_opt_int_range(make_null(), -10, 10, &out, who) && !g_has_error && (out == 73), "eigs_opt_int_range null");
        check(!eigs_slot_opt_int_range(slot_null(), -10, 10, &out, who) && !g_has_error && (out == 73), "eigs_slot_opt_int_range null");
        reset_error();
        check(!eigs_opt_int_range(bad, -10, 10, &out, who) && g_has_error && g_error_kind == EK_TYPE && (out == 73), "eigs_opt_int_range wrong type");
        g_strict = 0; reset_error();
        check(eigs_elem_int_range(bad, -10, 10, &out, who) && (out == 0) && !g_has_error, "eigs_elem_int_range non-strict zero");
        reset_error(); (void)eigs_elem_int_range(make_bool(1), -10, 10, &out, who); check(g_has_error && g_error_kind == EK_TYPE, "eigs_elem_int_range bool always refuses");
        g_strict = 1; reset_error(); (void)eigs_elem_int_range(bad, -10, 10, &out, who); check(g_has_error && g_error_kind == EK_TYPE, "eigs_elem_int_range strict wrong type");
        reset_error(); (void)eigs_list_int_range(NULL, 0, -10, 10, &out, who); check(g_has_error && g_error_kind == EK_TYPE, "eigs_list_int_range missing argument");
        check(bad->refcount == refs, "int_range heap refusal ownership");
    }
    {
        int out = 73;
        reset_error();
        check(!eigs_opt_bounded(NULL, 0, 255, &out, who) && !g_has_error && (out == 73), "eigs_opt_bounded absent");
        check(!eigs_opt_bounded(make_null(), 0, 255, &out, who) && !g_has_error && (out == 73), "eigs_opt_bounded null");
        check(!eigs_slot_opt_bounded(slot_null(), 0, 255, &out, who) && !g_has_error && (out == 73), "eigs_slot_opt_bounded null");
        reset_error();
        check(!eigs_opt_bounded(bad, 0, 255, &out, who) && g_has_error && g_error_kind == EK_TYPE && (out == 73), "eigs_opt_bounded wrong type");
        g_strict = 0; reset_error();
        check(eigs_elem_bounded(bad, 0, 255, &out, who) && (out == 0) && !g_has_error, "eigs_elem_bounded non-strict zero");
        reset_error(); (void)eigs_elem_bounded(make_bool(1), 0, 255, &out, who); check(g_has_error && g_error_kind == EK_TYPE, "eigs_elem_bounded bool always refuses");
        g_strict = 1; reset_error(); (void)eigs_elem_bounded(bad, 0, 255, &out, who); check(g_has_error && g_error_kind == EK_TYPE, "eigs_elem_bounded strict wrong type");
        reset_error(); (void)eigs_list_bounded(NULL, 0, 0, 255, &out, who); check(g_has_error && g_error_kind == EK_TYPE, "eigs_list_bounded missing argument");
        check(bad->refcount == refs, "bounded heap refusal ownership");
    }
    {
        int64_t out = 73;
        reset_error();
        check(!eigs_opt_magnitude(NULL, -10, 10, &out, who) && !g_has_error && (out == 73), "eigs_opt_magnitude absent");
        check(!eigs_opt_magnitude(make_null(), -10, 10, &out, who) && !g_has_error && (out == 73), "eigs_opt_magnitude null");
        check(!eigs_slot_opt_magnitude(slot_null(), -10, 10, &out, who) && !g_has_error && (out == 73), "eigs_slot_opt_magnitude null");
        reset_error();
        check(!eigs_opt_magnitude(bad, -10, 10, &out, who) && g_has_error && g_error_kind == EK_TYPE && (out == 73), "eigs_opt_magnitude wrong type");
        g_strict = 0; reset_error();
        check(eigs_elem_magnitude(bad, -10, 10, &out, who) && (out == 0) && !g_has_error, "eigs_elem_magnitude non-strict zero");
        reset_error(); (void)eigs_elem_magnitude(make_bool(1), -10, 10, &out, who); check(g_has_error && g_error_kind == EK_TYPE, "eigs_elem_magnitude bool always refuses");
        g_strict = 1; reset_error(); (void)eigs_elem_magnitude(bad, -10, 10, &out, who); check(g_has_error && g_error_kind == EK_TYPE, "eigs_elem_magnitude strict wrong type");
        reset_error(); (void)eigs_list_magnitude(NULL, 0, -10, 10, &out, who); check(g_has_error && g_error_kind == EK_TYPE, "eigs_list_magnitude missing argument");
        check(bad->refcount == refs, "magnitude heap refusal ownership");
    }
    reset_error(); val_decref(bad);
}

static void container_and_buffer(void) {
    Value *list = make_list_heap(1), *dict = make_dict(1);
    Value *str = make_str("owned-container-control");
    list_append_owned(list, str);
    dict_set_owned(dict, "x", make_str("owned-dict-control"));
    double f = -73; int64_t i = -73;
    list_set_int(list, 0, INT64_C(9007199254740993));
    check(list_get_int(list, 0, &i) && i == INT64_C(9007199254740993), "list_set/get_int boxed exact");
    check(!list_get_f64(list, 0, &f) && f == -73, "list_get_f64 refuses int");
    list_rewrite_int(list, 0, INT64_MAX);
    check(list_get_int(list, 0, &i) && i == INT64_MAX, "list_rewrite_int boxed ownership");
    list_set_f64(list, 0, 1.5);
    check(list_get_f64(list, 0, &f) && f == 1.5, "list_set/get_f64");
    check(!list_get_int(list, 0, &i), "list_get_int refuses float");
    list_rewrite_f64(list, 0, 42.0);
    check(list_get_f64(list, 0, &f) && f == 42.0, "list_rewrite_f64");
    list_append_int(list, INT64_MIN);
    check(list_get_int(list, 1, &i) && i == INT64_MIN, "list_append_int boxed exact");
    list_append_f64(list, 2.5);
    check(list_get_f64(list, 2, &f) && f == 2.5, "list_append_f64");
    dict_value_set_int(dict, 0, INT64_C(9007199254740993));
    check(dict_value_get_int(dict, 0, &i) && i == INT64_C(9007199254740993), "dict_value_set/get_int boxed exact");
    check(!dict_value_get_f64(dict, 0, &f), "dict_value_get_f64 refuses int");
    dict_value_rewrite_int(dict, 0, INT64_MIN);
    check(dict_value_get_int(dict, 0, &i) && i == INT64_MIN, "dict_value_rewrite_int");
    dict_value_set_f64(dict, 0, 2.5);
    check(dict_value_get_f64(dict, 0, &f) && f == 2.5, "dict_value_set/get_f64");
    check(!dict_value_get_int(dict, 0, &i), "dict_value_get_int refuses float");
    dict_value_rewrite_f64(dict, 0, 42.0);
    check(dict_value_get_f64(dict, 0, &f) && f == 42, "dict_value_rewrite_f64");
    /* Typed container getters report storage kind, including IEEE payloads;
     * validation belongs to the checked _arg readers, not the storage lens. */
    list_values_storage(list)[0] = slot_from_f64(NAN);
    dict_values_storage(dict)[0] = slot_from_f64(INFINITY);
    check(list_get_f64(list, 0, &f) && isnan(f), "list_get_f64 IEEE storage");
    check(!list_get_int(list, 0, &i), "list_get_int refuses IEEE float");
    check(dict_value_get_f64(dict, 0, &f) && isinf(f), "dict_value_get_f64 IEEE storage");
    check(!dict_value_get_int(dict, 0, &i), "dict_value_get_int refuses IEEE float");
    val_decref(list); val_decref(dict);
    double cells[] = { 0, 255, -1, 256, 1.5, 9007199254740993.0,
                       -9223372036854775808.0, 9223372036854775808.0, NAN, INFINITY };
    Value buf = { .type = VAL_BUFFER };
    buf.data.buffer.data = cells;
    buf.data.buffer.count = (int)(sizeof cells / sizeof cells[0]);
    for (int k = 0; k < buf.data.buffer.count; k++) {
        reset_error(); uint8_t byte = 73;
        int rc = buffer_byte_at(&buf, k, &byte, "reader");
        check(rc == (k < 2), "buffer_byte_at exact boundary");
        check(rc ? byte == (uint8_t)cells[k] : byte == 73, "buffer_byte_at output");
        reset_error(); i = -73;
        rc = buffer_index_at(&buf, k, &i, "reader");
        check(rc == (k < 7 && k != 4), "buffer_index_at exact conversion");
        if (k == 5) check(rc && i == INT64_C(9007199254740992), "buffer index is stored rounded float");
        if (k == 6) check(rc && i == INT64_MIN, "buffer index int64 lower edge");
        reset_error(); f = buffer_read_f64(&buf, k);
        check(k < 8 ? !g_has_error && f == cells[k] : g_has_error && g_error_kind == EK_VALUE,
              "buffer_read_f64 finite data and nonfinite refusal");
    }
    int saved_strict = g_strict;
    unsigned saved_flags = g_math_flags;
    for (int strict = 0; strict <= 1; strict++) {
        g_strict = strict;
        g_math_flags = 0;
        reset_error();
        f = buffer_read_f64(&buf, 8);
        check(g_has_error && g_error_kind == EK_VALUE && f == 0.0,
              "buffer_read_f64 NaN refusal in both modes");
        check(g_math_flags == (strict ? EIGS_MATH_INVALID : 0),
              "buffer_read_f64 strict NaN retains INVALID only");
        check(strstr(g_error_raw, strict ? "not a number" : "expected a finite number") != NULL,
              "buffer_read_f64 strict NaN retains its diagnostic");
    }
    g_strict = saved_strict;
    g_math_flags = saved_flags;
    reset_error(); check(!buffer_index_at(&buf, -1, &i, "reader") && g_error_kind == EK_INDEX, "buffer negative index");
    reset_error(); check(!buffer_byte_at(&buf, buf.data.buffer.count, (uint8_t *)&i, "reader") && g_error_kind == EK_INDEX, "buffer upper index");
    reset_error();
    Value *normal = make_float(1.5), *permanent = make_float_permanent(2.5);
    check(normal->type == VAL_FLOAT && eigs_float_arg(normal, "reader") == 1.5, "make_float");
    check(permanent->type == VAL_FLOAT && eigs_float_arg(permanent, "reader") == 2.5, "make_float_permanent");
    val_decref(normal); val_decref(permanent);
}

int main(void) {
    EigsState *st = eigs_open();
    if (!st) { puts("phase2-readers-test: FAIL eigs_open"); return 1; }
    g_try_depth = 1;             /* raises are assertions, never uncaught stderr */
    for (unsigned k = 0; k < sizeof reader_cases / sizeof reader_cases[0]; k++)
        exercise_case(&reader_cases[k]);
    check(reader_calls == 49 * (int)(sizeof reader_cases / sizeof reader_cases[0]),
          "all 49 declared reader forms executed for every fixture");
    boundaries(); optional_and_types(); container_and_buffer();
    reset_error(); g_try_depth = 0;
    eigs_close(st);
    printf("phase2-readers-test: %s cases=%zu forms=%d checks=%d failures=%d\n",
           reader_failures ? "FAIL" : "PASS", sizeof reader_cases / sizeof reader_cases[0],
           reader_calls / (int)(sizeof reader_cases / sizeof reader_cases[0]), reader_checks, reader_failures);
    return reader_failures ? 1 : 0;
}
