/* #1758 R1.6e: Q7 through the real no-SDL amalgamation. */
#include "eigenscript_all.c"
static int checks, failures;
static void check(int ok, const char *name) {
    ++checks; if (!ok) { ++failures; printf("phase2-q7-test: FAIL %s\n", name); }
}
static void clear_error(void) {
    eigs_clear_error_value(); g_has_error = g_error_print_pending = 0;
    g_error_msg[0] = g_error_raw[0] = 0;
}
static EigsShape shape(EigsShapeKind kind, const double *v, int n) {
    Value *args = make_list_heap(n);
    /* Raw fixtures intentionally bypass the current scalar constructor clamp. */
    for (int i=0; i<n; ++i) list_values_storage(args)[i]=slot_from_f64(v[i]);
    args->data.list.count=n;
    EigsShape out; EigsRect area = {0,0,640,480};
    check(eigs_geom_shape(args,0,kind,&area,&out,"q7-test"), "shape read");
    val_decref(args); return out;
}
int main(void) {
    EigsState *st = eigs_open(); if (!st) return 1;
    g_try_depth = 1;
    EigsShape s = shape(EIGS_RECT, (double[]){-3e9,0,6e9,10},4);
    check(!s.empty && s.x==0 && s.y==0 && s.w==640 && s.h==10, "whole rect, not per-vertex saturation");
    s = shape(EIGS_LINE,(double[]){-640,-480,1280,960},4);
    check(!s.empty && s.x==0 && s.y==0 && s.x2==640 && s.y2==480, "Liang-Barsky slope");
    s = shape(EIGS_LINE,(double[]){-100,10,100,110},4);
    check(!s.empty && s.x==0 && s.y==60 && s.x2==100 && s.y2==110,"line intersection preserves slope");
    s = shape(EIGS_LINE,(double[]){-0x1p100,10,0x1p100,10},4);
    check(!s.empty && s.x==0 && s.y==10 && s.x2==640 && s.y2==10,"huge line retains visible interval");
    s = shape(EIGS_LINE,(double[]){639.25,10,639.25,20},4);
    check(!s.empty && s.x==639 && s.x2==639,"fractional last-pixel line");
    s = shape(EIGS_LINE,(double[]){-0x1p100,-0x1p100,0x1p100,0x1p100},4);
    check(!s.empty && s.x==0 && s.y==0 && s.x2==480 && s.y2==480,"huge diagonal slope");
    s = shape(EIGS_LINE,(double[]){12,13,12,13},4);
    check(!s.empty && s.x==12 && s.y==13 && s.x2==12 && s.y2==13,"degenerate visible line");
    s = shape(EIGS_RECT,(double[]){0,0,0,10},4); check(s.empty,"empty rectangle");
    s = shape(EIGS_CIRCLE,(double[]){0,0,-1},3); check(s.empty,"negative radius");
    double hard_line[4]={-0x1p80,0x1.bfffb00000002p7,0x1.0000000000001p80,0x1.700014p9};
    s=shape(EIGS_LINE,hard_line,4);
    check(!s.empty && s.x==0 && s.y==480 && s.x2==320 && s.y2==480,"boundary determinant cancellation");
    Value *custom=make_list_heap(4);
    for (int k=0;k<4;++k) list_values_storage(custom)[k]=slot_from_f64(hard_line[k]);
    custom->data.list.count=4;EigsRect translated={0,480,640,480};
    check(eigs_geom_shape(custom,0,EIGS_LINE,&translated,&s,"q7-test"),"translated drawable line read");
    check(!s.empty && s.x==320 && s.y==480 && s.x2==640 && s.y2==480,"translated drawable determinant cancellation");
    val_decref(custom);
    s=shape(EIGS_LINE,(double[]){0,0.5,0x1p100,0x1p99},4);
    check(!s.empty && s.x2==640 && s.y2==320,"sub-ulp Q4 boundary tie");
    s=shape(EIGS_LINE,(double[]){-1e308,-1e308,1e308,1e308},4);
    check(!s.empty && s.x==0 && s.y==0 && s.x2==480 && s.y2==480,"binary64 product exponent extremes");
    s=shape(EIGS_LINE,(double[]){-1e308,-0x1p-1074,1e308,0x1p-1074},4);
    check(!s.empty && s.x==0 && s.y==0 && s.x2==640 && s.y2==0,"binary64 subnormal edge products");
    s = shape(EIGS_CIRCLE,(double[]){320,240,3e9},3);
    check(!s.empty && s.x==0 && s.y==0 && s.w==640 && s.h==480,"huge circle visible loops only");
    s = shape(EIGS_RRECT,(double[]){-3e9,-3e9,6e9,6e9,10},5);
    check(!s.empty && s.w==640 && s.h==480,"huge rrect");
    s = shape(EIGS_RECT,(double[]){-1e308,0,1.5e308,10},4);
    check(!s.empty && s.w==640,"finite intermediate range");
    s = shape(EIGS_POINT,(double[]){3e9,0},2); check(s.empty,"outside point");
    s = shape(EIGS_RECT,(double[]){20.5,20,2,2},4);
    check(s.x==21 && s.w==2,"round after intersection");
    int bounded=-1; Value v={.type=VAL_FLOAT}; VAL_F64_RAW(&v)=300;
    check(eigs_bounded_arg(&v,0,255,&bounded,"q7-test") && bounded==255,"bounded clamp");
    VAL_F64_RAW(&v)=-1.5;
    check(eigs_bounded_arg(&v,-32767,32767,&bounded,"q7-test") && bounded==-2,"Q4 negative tie");
    int64_t mag=0; VAL_F64_RAW(&v)=3e12;
    check(!eigs_magnitude_arg(&v,0,INT_MAX,&mag,"q7-test") && g_has_error && g_error_kind==EK_VALUE && strstr(g_error_raw,"q7-test"),"magnitude refusal");
    clear_error();
    Value *args=make_list_heap(2); list_append_owned(args,make_float(0)); list_append_owned(args,make_float(0));
    list_values_storage(args)[0]=slot_from_f64(INFINITY);
    EigsRect area={0,0,640,480};
    check(!eigs_geom_shape(args,0,EIGS_POINT,&area,&s,"q7-test") && g_error_kind==EK_VALUE,"nonfinite refusal");
    clear_error(); val_decref(args);
    args=make_list_heap(2);
    check(!eigs_geom_shape(args,0,EIGS_POINT,&area,&s,"q7-test") && g_error_kind==EK_TYPE,"missing coordinate");
    clear_error();
    list_append_owned(args,make_str("bad")); list_append_owned(args,make_int(0));
    check(!eigs_geom_shape(args,0,EIGS_POINT,&area,&s,"q7-test") && g_error_kind==EK_TYPE,"non-number coordinate");
    clear_error(); val_decref(args);
    Value *boxed=make_int(INT64_C(9007199254740993)); args=make_list_heap(2);
    list_append(args,boxed);list_append_owned(args,make_int(0)); int refs=boxed->refcount;
    check(eigs_geom_shape(args,0,EIGS_POINT,&area,&s,"q7-test"),"boxed integer geometry");
    check(s.empty && boxed->refcount==refs,"boxed coordinate borrowed on clipped success");
    val_decref(args);val_decref(boxed);g_try_depth=0;eigs_close(st);
    printf("phase2-q7-test: %s checks=%d failures=%d\n",failures?"FAIL":"PASS",checks,failures);
    return failures?1:0;
}
