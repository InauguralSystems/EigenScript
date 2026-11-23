#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "eigs_embed.h"
#include "eigenscript.h"
static int examined,declared,failed;
static void fail(const char*s,const char*w){fprintf(stderr,"FAIL: %s: %s\n",s,w);failed++;}
static const char *detail(const char *s){const char*p=s?strrchr(s,':'):NULL;return p?p:s;}
static void binary(EigsOperator op,EigsSlot a,EigsSlot b,const char*src){
 EigsValue*w=eigs_eval_string(src);int we=eigs_has_error();char*wk=we&&eigs_last_error_kind()?xstrdup(eigs_last_error_kind()):NULL;char*wm=we&&eigs_last_error_message()?xstrdup(eigs_last_error_message()):NULL;eigs_clear_error();
 EigsSlot gs=eigs_op_binary(op,a,b);int ge=eigs_has_error();
 if(we!=ge)fail(src,"VM/export error status differs");else if(we){if(!wk||!eigs_last_error_kind()||strcmp(wk,eigs_last_error_kind()))fail(src,"error kind differs");if(!wm||!eigs_last_error_message()||strcmp(detail(wm),detail(eigs_last_error_message())))fail(src,"error message differs");}
 else{EigsValue*g=slot_to_value(gs);char*ws=value_to_string(w),*gt=value_to_string(g);if(w->type!=g->type)fail(src,"result kind differs");if(!values_equal(w,g)&&strcmp(ws,"nan"))fail(src,"result value differs");if(strcmp(ws,gt))fail(src,"printed form differs");free(ws);free(gt);eigs_value_release(g);}free(wk);free(wm);if(w)eigs_value_release(w);eigs_clear_error();slot_decref(gs);examined++;declared++;}
static void unary(EigsOperator op,EigsSlot a,const char*src){
 EigsValue*w=eigs_eval_string(src);int we=eigs_has_error();char*wk=we&&eigs_last_error_kind()?xstrdup(eigs_last_error_kind()):NULL;char*wm=we&&eigs_last_error_message()?xstrdup(eigs_last_error_message()):NULL;eigs_clear_error();EigsSlot gs=eigs_op_unary(op,a);int ge=eigs_has_error();
 if(we!=ge)fail(src,"VM/export error status differs");else if(we){if(!wk||!eigs_last_error_kind()||strcmp(wk,eigs_last_error_kind()))fail(src,"error kind differs");if(!wm||!eigs_last_error_message()||strcmp(detail(wm),detail(eigs_last_error_message())))fail(src,"error message differs");}else{EigsValue*g=slot_to_value(gs);char*ws=value_to_string(w),*gt=value_to_string(g);if(w->type!=g->type)fail(src,"result kind differs");if(!values_equal(w,g)&&strcmp(ws,"nan"))fail(src,"result value differs");if(strcmp(ws,gt))fail(src,"printed form differs");free(ws);free(gt);eigs_value_release(g);}free(wk);free(wm);if(w)eigs_value_release(w);eigs_clear_error();slot_decref(gs);examined++;declared++;}
#define B(OP,A,B,S) binary(EIGS_OP_##OP,(A),(B),(S))
int main(void){EigsState*st=eigs_open();if(!st)return 2;EigsValue*nv=eigs_value_new_num(NAN);eigs_set_global("generic_nan",nv);eigs_value_release(nv);EigsSlot i1=slot_from_int(1),i2=slot_from_int(2),i3=slot_from_int(3),f05=slot_from_f64(.5),f25=slot_from_f64(2.5),str=slot_from_value(make_str("a"));
#define FOUR(OP,TOK) B(OP,i2,i3,"2 " TOK " 3");B(OP,f25,f05,"2.5 " TOK " 0.5");B(OP,i2,f05,"2 " TOK " 0.5");B(OP,f05,i2,"0.5 " TOK " 2");B(OP,str,i1,"\"a\" " TOK " 1")
 FOUR(ADD,"+");FOUR(SUB,"-");FOUR(MUL,"*");FOUR(DIV,"/");FOUR(IDIV,"//");FOUR(MOD,"%");FOUR(BAND,"&");FOUR(BOR,"|");FOUR(BXOR,"^");FOUR(SHL,"<<");FOUR(SHR,">>");FOUR(EQ,"==");FOUR(NE,"!=");FOUR(LT,"<");FOUR(GT,">");FOUR(LE,"<=");FOUR(GE,">=");
#define NR(OP,TOK) B(OP,slot_from_f64(NAN),i1,"generic_nan " TOK " 1");B(OP,i1,slot_from_f64(NAN),"1 " TOK " generic_nan")
 NR(EQ,"==");NR(NE,"!=");NR(LT,"<");NR(GT,">");NR(LE,"<=");NR(GE,">=");
 B(ADD,slot_from_int(INT64_MAX),i1,"9223372036854775807 + 1");B(SUB,slot_from_int(INT64_MIN),i1,"(-9223372036854775807 - 1) - 1");B(MUL,slot_from_int(INT64_MAX),i2,"9223372036854775807 * 2");B(IDIV,slot_from_int(INT64_MIN),slot_from_int(-1),"(-9223372036854775807 - 1) // -1");B(MOD,slot_from_int(INT64_MIN),slot_from_int(-1),"(-9223372036854775807 - 1) % -1");
#define Z(OP,TOK) B(OP,i2,slot_from_int(0),"2 " TOK " 0");B(OP,i2,slot_from_f64(0),"2 " TOK " 0.0")
 Z(DIV,"/");Z(IDIV,"//");Z(MOD,"%");B(SHL,i2,slot_from_int(-1),"2 << -1");B(SHL,i2,slot_from_int(64),"2 << 64");B(SHR,i2,slot_from_int(-1),"2 >> -1");B(SHR,i2,slot_from_int(64),"2 >> 64");
 unary(EIGS_OP_NEG,i2,"-2");unary(EIGS_OP_NEG,f25,"-2.5");unary(EIGS_OP_NEG,str,"-\"a\"");unary(EIGS_OP_NEG,slot_from_int(INT64_MIN),"-(-9223372036854775807 - 1)");unary(EIGS_OP_NOT,i2,"not 2");unary(EIGS_OP_NOT,f25,"not 2.5");unary(EIGS_OP_NOT,str,"not \"a\"");unary(EIGS_OP_BNOT,i2,"~2");unary(EIGS_OP_BNOT,slot_from_f64(2),"~2.0");unary(EIGS_OP_BNOT,str,"~\"a\"");slot_decref(str);eigs_close(st);if(examined!=declared||declared<=0||failed)return 1;printf("PASS: generic operator exports strict=%s examined=%d declared=%d\n",getenv("EIGS_STRICT")?getenv("EIGS_STRICT"):"unset",examined,declared);return 0;}
