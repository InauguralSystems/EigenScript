/* Differential test of eigs_op_binary / eigs_op_unary over the operand
 * population owned by generic_ops_gen.py (#2512). */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "eigs_embed.h"
#include "eigenscript.h"
#include "generic_ops_operands.h"
static int examined, failed;
static void fail(const char *s,const char *w){fprintf(stderr,"FAIL: %s: %s\n",s,w);failed++;}
static const char *detail(const char *s){const char*p=s?strstr(s,": "):NULL;return p?p+2:s;}
static void compare_binary(EigsOperator op,const char*a,const char*b,const char*tok){
 char src[512];snprintf(src,sizeof src,"%s %s %s",a,tok,b);
 EigsValue*w=eigs_eval_string(src);int we=eigs_has_error();char*wk=we&&eigs_last_error_kind()?xstrdup(eigs_last_error_kind()):NULL;char*wm=we&&eigs_last_error_message()?xstrdup(eigs_last_error_message()):NULL;eigs_clear_error();
 EigsValue*av=eigs_eval_string(a);if(eigs_has_error()){fail(a,"operand setup raised");eigs_clear_error();goto done;} EigsValue*bv=eigs_eval_string(b);if(eigs_has_error()){fail(b,"operand setup raised");eigs_value_release(av);eigs_clear_error();goto done;}
 EigsSlot as=slot_from_value(av),bs=slot_from_value(bv),gs=eigs_op_binary(op,as,bs);int ge=eigs_has_error();
 if(we!=ge)fail(src,"VM/export error status differs");else if(we){if(!wk||!eigs_last_error_kind()||strcmp(wk,eigs_last_error_kind()))fail(src,"error kind differs");if(!wm||!eigs_last_error_message()||strcmp(detail(wm),detail(eigs_last_error_message())))fail(src,"error message differs");}
 else {EigsValue*g=slot_to_value(gs);char*ws=value_to_string(w),*gt=value_to_string(g);if(w->type!=g->type)fail(src,"result kind differs");if(!values_equal(w,g)&&strcmp(ws,"nan"))fail(src,"result value differs");if(strcmp(ws,gt))fail(src,"printed form differs");free(ws);free(gt);eigs_value_release(g);}
 slot_decref(gs);slot_decref(as);slot_decref(bs);eigs_clear_error();
done: free(wk);free(wm);if(w)eigs_value_release(w);examined++;
}
static void compare_unary(EigsOperator op,const char*a,const char*tok){
 char src[256];snprintf(src,sizeof src,"%s%s",tok,a);EigsValue*w=eigs_eval_string(src);int we=eigs_has_error();char*wk=we&&eigs_last_error_kind()?xstrdup(eigs_last_error_kind()):NULL;char*wm=we&&eigs_last_error_message()?xstrdup(eigs_last_error_message()):NULL;eigs_clear_error();EigsValue*av=eigs_eval_string(a);if(eigs_has_error()){fail(a,"operand setup raised");eigs_clear_error();goto done;}EigsSlot as=slot_from_value(av),gs=eigs_op_unary(op,as);int ge=eigs_has_error();if(we!=ge)fail(src,"VM/export error status differs");else if(we){if(!wk||!eigs_last_error_kind()||strcmp(wk,eigs_last_error_kind()))fail(src,"error kind differs");if(!wm||!eigs_last_error_message()||strcmp(detail(wm),detail(eigs_last_error_message())))fail(src,"error message differs");}else{EigsValue*g=slot_to_value(gs);char*ws=value_to_string(w),*gt=value_to_string(g);if(w->type!=g->type)fail(src,"result kind differs");if(!values_equal(w,g)&&strcmp(ws,"nan"))fail(src,"result value differs");if(strcmp(ws,gt))fail(src,"printed form differs");free(ws);free(gt);eigs_value_release(g);}slot_decref(gs);slot_decref(as);eigs_clear_error();
done: free(wk);free(wm);if(w)eigs_value_release(w);examined++;
}
int main(void){EigsState*st=eigs_open();if(!st)return 2;EigsValue*setup=eigs_eval_string("define fnv(x) as:\n    return x\n");if(eigs_has_error()){fprintf(stderr,"FAIL: setup: %s\n",eigs_last_error_message());return 2;}eigs_value_release(setup);
 EigsOperator ops[]={EIGS_OP_ADD,EIGS_OP_SUB,EIGS_OP_MUL,EIGS_OP_DIV,EIGS_OP_IDIV,EIGS_OP_MOD,EIGS_OP_BAND,EIGS_OP_BOR,EIGS_OP_BXOR,EIGS_OP_SHL,EIGS_OP_SHR,EIGS_OP_EQ,EIGS_OP_NE,EIGS_OP_LT,EIGS_OP_GT,EIGS_OP_LE,EIGS_OP_GE};const char*toks[]={"+","-","*","/","//","%","&","|","^","<<",">>","==","!=","<",">","<=",">="};
 for(size_t k=0;k<sizeof ops/sizeof ops[0];k++)for(size_t i=0;i<GENERIC_OPERAND_COUNT;i++)for(size_t j=0;j<GENERIC_OPERAND_COUNT;j++)compare_binary(ops[k],generic_operands[i],generic_operands[j],toks[k]);
 EigsOperator un[]={EIGS_OP_NEG,EIGS_OP_NOT,EIGS_OP_BNOT};const char*ut[]={"-","not ","~"};for(size_t k=0;k<3;k++)for(size_t i=0;i<GENERIC_OPERAND_COUNT;i++)compare_unary(un[k],generic_operands[i],ut[k]);
 eigs_close(st);if(failed)return 1;printf("PASS: generic operator exports strict=%s examined=%d\n",getenv("EIGS_STRICT")?getenv("EIGS_STRICT"):"unset",examined);return 0;}
