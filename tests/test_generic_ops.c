#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "eigs_embed.h"
#include "eigenscript.h"
static int examined,declared,failed;
static void fail(const char*s,const char*w){fprintf(stderr,"FAIL: %s: %s\n",s,w);failed++;}

static const char *detail(const char *s);
typedef struct Expected { char state[8], expr[128], result[8], kind[32], text[256]; int seen; } Expected;
static Expected expected[512]; static int expected_count;
static const char *state_name(void){const char*s=getenv("EIGS_STRICT");return s?s:"unset";}
static void load_expected(void){
 FILE*f=fopen("tests/generic_ops_expected.tsv","r"); if(!f)f=fopen("../tests/generic_ops_expected.tsv","r");
 if(!f){perror("generic_ops_expected.tsv");exit(2);} char line[768];
 while(fgets(line,sizeof line,f)){if(line[0]=='#')continue;char*cols[7],*p=line;int n=0;while(n<7&&(cols[n]=strsep(&p,"\t")))n++;if(n!=7)continue;cols[6][strcspn(cols[6],"\r\n")]=0;if(strcmp(cols[0],state_name()))continue;Expected*e=&expected[expected_count++];snprintf(e->state,sizeof e->state,"%s",cols[0]);snprintf(e->expr,sizeof e->expr,"%s",cols[3]);snprintf(e->result,sizeof e->result,"%s",cols[4]);snprintf(e->kind,sizeof e->kind,"%s",cols[5]);snprintf(e->text,sizeof e->text,"%s",cols[6]);}
 fclose(f);declared=expected_count;if(!expected_count){fprintf(stderr,"FAIL: oracle has no rows for state %s\n",state_name());exit(2);}
}
static Expected*oracle(const char*expr){for(int i=0;i<expected_count;i++)if(!strcmp(expected[i].expr,expr)){if(expected[i].seen)fail(expr,"oracle row reached twice");expected[i].seen=1;return &expected[i];}fail(expr,"missing oracle row");return NULL;}
static const char*value_kind(Value*v){switch(v->type){case VAL_INT:case VAL_FLOAT:return "num";case VAL_BOOL:return "bool";case VAL_STR:return "str";case VAL_NULL:return "null";default:return val_type_name(v->type);}}
static void check_oracle(Expected*e,int is_error,EigsValue*v){if(!e)return;if(is_error){if(strcmp(e->result,"error"))fail(e->expr,"export raised but oracle has value");else if(!eigs_last_error_kind()||strcmp(e->kind,eigs_last_error_kind()))fail(e->expr,"oracle error kind differs");else if(!eigs_last_error_message()||strcmp(e->text,detail(eigs_last_error_message())))fail(e->expr,"oracle error message differs");}else{char*s=value_to_string(v);if(strcmp(e->result,"value"))fail(e->expr,"export returned but oracle has error");else if(strcmp(e->kind,value_kind(v)))fail(e->expr,"oracle value kind differs");else if(strcmp(e->text,s))fail(e->expr,"oracle printed form differs");free(s);}}
static const char *detail(const char *s){const char*p=s?strstr(s,": "):NULL;return p?p+2:s;}
static void binary(EigsOperator op,EigsSlot a,EigsSlot b,const char*src){
 EigsValue*w=eigs_eval_string(src);int we=eigs_has_error();char*wk=we&&eigs_last_error_kind()?xstrdup(eigs_last_error_kind()):NULL;char*wm=we&&eigs_last_error_message()?xstrdup(eigs_last_error_message()):NULL;eigs_clear_error();
 EigsSlot gs=eigs_op_binary(op,a,b);int ge=eigs_has_error();Expected*oe=oracle(src);EigsValue*og=ge?NULL:slot_to_value(gs);check_oracle(oe,ge,og);if(og)eigs_value_release(og);
 if(we!=ge)fail(src,"VM/export error status differs");else if(we){if(!wk||!eigs_last_error_kind()||strcmp(wk,eigs_last_error_kind()))fail(src,"error kind differs");if(!wm||!eigs_last_error_message()||strcmp(detail(wm),detail(eigs_last_error_message())))fail(src,"error message differs");}
 else{EigsValue*g=slot_to_value(gs);char*ws=value_to_string(w),*gt=value_to_string(g);if(w->type!=g->type)fail(src,"result kind differs");if(!values_equal(w,g)&&strcmp(ws,"nan"))fail(src,"result value differs");if(strcmp(ws,gt))fail(src,"printed form differs");free(ws);free(gt);eigs_value_release(g);}free(wk);free(wm);if(w)eigs_value_release(w);eigs_clear_error();slot_decref(gs);examined++;}
static void unary(EigsOperator op,EigsSlot a,const char*src){
 EigsValue*w=eigs_eval_string(src);int we=eigs_has_error();char*wk=we&&eigs_last_error_kind()?xstrdup(eigs_last_error_kind()):NULL;char*wm=we&&eigs_last_error_message()?xstrdup(eigs_last_error_message()):NULL;eigs_clear_error();EigsSlot gs=eigs_op_unary(op,a);int ge=eigs_has_error();Expected*oe=oracle(src);EigsValue*og=ge?NULL:slot_to_value(gs);check_oracle(oe,ge,og);if(og)eigs_value_release(og);
 if(we!=ge)fail(src,"VM/export error status differs");else if(we){if(!wk||!eigs_last_error_kind()||strcmp(wk,eigs_last_error_kind()))fail(src,"error kind differs");if(!wm||!eigs_last_error_message()||strcmp(detail(wm),detail(eigs_last_error_message())))fail(src,"error message differs");}else{EigsValue*g=slot_to_value(gs);char*ws=value_to_string(w),*gt=value_to_string(g);if(w->type!=g->type)fail(src,"result kind differs");if(!values_equal(w,g)&&strcmp(ws,"nan"))fail(src,"result value differs");if(strcmp(ws,gt))fail(src,"printed form differs");free(ws);free(gt);eigs_value_release(g);}free(wk);free(wm);if(w)eigs_value_release(w);eigs_clear_error();slot_decref(gs);examined++;}
static void binary_eval(EigsOperator op,const char*a,const char*b,const char*tok){
 EigsValue*av=eigs_eval_string(a);eigs_clear_error();EigsValue*bv=eigs_eval_string(b);eigs_clear_error();char src[256];snprintf(src,sizeof src,"%s %s %s",a,tok,b);binary(op,slot_from_value(av),slot_from_value(bv),src);eigs_value_release(av);eigs_value_release(bv);
}
#define B(OP,A,B,S) binary(EIGS_OP_##OP,(A),(B),(S))
int main(void){load_expected();EigsState*st=eigs_open();if(!st)return 2;EigsValue*nv=eigs_value_new_num(NAN);eigs_set_global("generic_nan",nv);eigs_value_release(nv);EigsSlot i1=slot_from_int(1),i2=slot_from_int(2),i3=slot_from_int(3),f05=slot_from_f64(.5),f25=slot_from_f64(2.5),str=slot_from_value(make_str("a"));
#define FOUR(OP,TOK) B(OP,i2,i3,"2 " TOK " 3");B(OP,f25,f05,"2.5 " TOK " 0.5");B(OP,i2,f05,"2 " TOK " 0.5");B(OP,f05,i2,"0.5 " TOK " 2");B(OP,str,i1,"\"a\" " TOK " 1")
 FOUR(ADD,"+");FOUR(SUB,"-");FOUR(MUL,"*");FOUR(DIV,"/");FOUR(IDIV,"//");FOUR(MOD,"%");FOUR(BAND,"&");FOUR(BOR,"|");FOUR(BXOR,"^");FOUR(SHL,"<<");FOUR(SHR,">>");FOUR(EQ,"==");FOUR(NE,"!=");FOUR(LT,"<");FOUR(GT,">");FOUR(LE,"<=");FOUR(GE,">=");
 B(IDIV,slot_from_int(-5),i2,"-5 // 2");B(LT,i2,i2,"2 < 2");B(ADD,slot_from_int(INT64_MAX),i1,"9223372036854775807 + 1");B(SUB,slot_from_int(INT64_MIN),i1,"(-9223372036854775807 - 1) - 1");B(MUL,slot_from_int(INT64_MAX),i2,"9223372036854775807 * 2");B(IDIV,slot_from_int(INT64_MIN),slot_from_int(-1),"(-9223372036854775807 - 1) // -1");B(MOD,slot_from_int(INT64_MIN),slot_from_int(-1),"(-9223372036854775807 - 1) % -1");
#define Z(OP,TOK) B(OP,i2,slot_from_int(0),"2 " TOK " 0");B(OP,i2,slot_from_f64(0),"2 " TOK " 0.0")
 Z(DIV,"/");Z(IDIV,"//");Z(MOD,"%");B(SHL,i2,slot_from_int(-1),"2 << -1");B(SHL,i2,slot_from_int(64),"2 << 64");B(SHR,i2,slot_from_int(-1),"2 >> -1");B(SHR,i2,slot_from_int(64),"2 >> 64");
 EigsOperator cops[]={EIGS_OP_EQ,EIGS_OP_NE,EIGS_OP_LT,EIGS_OP_GT,EIGS_OP_LE,EIGS_OP_GE};const char*ctoks[]={"==","!=","<",">","<=",">="};
 for(int j=0;j<6;j++){binary_eval(cops[j],"\"a\"","\"a\"",ctoks[j]);binary_eval(cops[j],"\"a\"","\"b\"",ctoks[j]);binary_eval(cops[j],"\"c\"","\"a\"",ctoks[j]);binary_eval(cops[j],"\"d\"","\"a\"",ctoks[j]);}
 binary_eval(EIGS_OP_BAND,"6","3.0","&");binary_eval(EIGS_OP_BOR,"6","1.0","|");binary_eval(EIGS_OP_BXOR,"5","1.0","^");binary_eval(EIGS_OP_SHL,"1","2.0","<<");binary_eval(EIGS_OP_BAND,"6","2.5","&");
 for(int j=0;j<4;j++){binary_eval(cops[j],"9007199254740993","9007199254740992.0",ctoks[j]);binary_eval(cops[j],"9007199254740992.0","9007199254740993",ctoks[j]);}
 EigsOperator ops[]={EIGS_OP_ADD,EIGS_OP_SUB,EIGS_OP_MUL,EIGS_OP_DIV,EIGS_OP_IDIV,EIGS_OP_MOD,EIGS_OP_BAND,EIGS_OP_BOR,EIGS_OP_BXOR,EIGS_OP_SHL,EIGS_OP_SHR,EIGS_OP_EQ,EIGS_OP_NE,EIGS_OP_LT,EIGS_OP_GT,EIGS_OP_LE,EIGS_OP_GE};const char*toks[]={"+","-","*","/","//","%","&","|","^","<<",">>","==","!=","<",">","<=",">="};const char*special[]={"generic_nan","-0.0","generic_inf","generic_ninf"};const char*special_b[]={"1.0","0.0","1.0","1.0"};
 EigsValue*iv=eigs_value_new_num(INFINITY);eigs_set_global("generic_inf",iv);eigs_value_release(iv);iv=eigs_value_new_num(-INFINITY);eigs_set_global("generic_ninf",iv);eigs_value_release(iv);
 for(int j=0;j<17;j++)for(int k=0;k<4;k++){char sx[128];snprintf(sx,sizeof sx,"%s %s %s",special[k],toks[j],special_b[k]);EigsSlot av=k==0?slot_from_f64(NAN):k==1?slot_from_f64(-0.0):k==2?slot_from_f64(INFINITY):slot_from_f64(-INFINITY);binary(ops[j],av,slot_from_f64(k==1?0.0:1.0),sx);}
 EigsSlot bad=eigs_op_binary(EIGS_OP_NEG,i2,i3);if(!eigs_has_error()||strcmp(eigs_last_error_kind(),"value")||!strstr(eigs_last_error_message(),"eigs_op_binary")||!strstr(eigs_last_error_message(),"17"))fail("binary NEG","invalid op was not named");slot_decref(bad);eigs_clear_error();
 bad=eigs_op_unary(EIGS_OP_ADD,i2);if(!eigs_has_error()||strcmp(eigs_last_error_kind(),"value")||!strstr(eigs_last_error_message(),"eigs_op_unary")||!strstr(eigs_last_error_message(),"0"))fail("unary ADD","invalid op was not named");slot_decref(bad);eigs_clear_error();
 bad=eigs_op_binary((EigsOperator)99,i2,i3);if(!eigs_has_error()||strcmp(eigs_last_error_kind(),"value")||!strstr(eigs_last_error_message(),"eigs_op_binary")||!strstr(eigs_last_error_message(),"99"))fail("binary 99","invalid op was not named");slot_decref(bad);eigs_clear_error();
 unary(EIGS_OP_NEG,i2,"-2");unary(EIGS_OP_NEG,f25,"-2.5");unary(EIGS_OP_NEG,str,"-\"a\"");unary(EIGS_OP_NEG,slot_from_int(INT64_MIN),"-(-9223372036854775807 - 1)");unary(EIGS_OP_NOT,i2,"not 2");unary(EIGS_OP_NOT,f25,"not 2.5");unary(EIGS_OP_NOT,str,"not \"a\"");unary(EIGS_OP_BNOT,i2,"~2");unary(EIGS_OP_BNOT,slot_from_f64(2),"~2.0");unary(EIGS_OP_BNOT,str,"~\"a\"");slot_decref(str);eigs_close(st);if(examined!=declared||declared!=expected_count||declared<=0||failed)return 1;printf("PASS: generic operator exports strict=%s examined=%d declared=%d\n",getenv("EIGS_STRICT")?getenv("EIGS_STRICT"):"unset",examined,declared);return 0;}
