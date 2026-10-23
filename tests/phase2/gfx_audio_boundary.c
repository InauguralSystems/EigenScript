/* #1758 R1.6d-D1: pre-register the stored-data audio boundary before migration.
 * Raw C payloads reach the real shared helper; strict script constructors
 * would refuse a NaN before any audio builtin could consume it. */
#define EIGENSCRIPT_EXT_GFX 1
#include "eigenscript_all.c"
#include "../../src/ext_gfx.c"
static int boundary_checks, boundary_failures;
static void check(int ok,const char *name) {
    ++boundary_checks;
    if (!ok) { ++boundary_failures; printf("phase2-gfx-audio-test: FAIL %s\n",name); }
}
static void reset_error(void) {
    eigs_clear_error_value();g_has_error=g_error_print_pending=0;
    g_error_msg[0]=g_error_raw[0]=0;g_math_flags=0;
}
static Value *buffer(int n) {
    Value *count=make_int(n);Value *b=builtin_buffer(count);val_decref(count);return b;
}
int main(void) {
    EigsState *st=eigs_open();if (!st) return 1;
    g_try_depth=1;
    for (int strict=0;strict<=1;++strict) {
        g_strict=strict;
        for (int k=0;k<4;++k) {
            Value *b=buffer(2);
            double first=k==0 || k==3 ? NAN : k==1 ? INFINITY : -INFINITY;
            b->data.buffer.data[0]=first;b->data.buffer.data[1]=k==3 ? INFINITY : 0.0;
            reset_error();int n=-77;int16_t *pcm=audio_convert_samples(b,&n);
            check(!pcm && g_has_error && g_error_kind==EK_VALUE,"stored nonfinite refuses before conversion");
            check(n==-77,"refusal does not publish a sample count");
            check(g_math_flags==(strict && isnan(first) ? EIGS_MATH_INVALID : 0),"strict first NaN flag only");
            check(strstr(g_error_raw,strict && isnan(first) ? "not a number" : "finite number")!=NULL,"data boundary first diagnostic");
            check((isnan(first) ? isnan(b->data.buffer.data[0]) : b->data.buffer.data[0]==first) &&
                  b->data.buffer.data[1]==(k==3 ? INFINITY : 0.0),"reader leaves stored payload unchanged");
            free(pcm);reset_error();val_decref(b);
        }
        Value *b=buffer(4);double data[4]={2.5,-3.0,0.5,-0.5};
        memcpy(b->data.buffer.data,data,sizeof data);int n=0;
        int16_t *pcm=audio_convert_samples(b,&n);
        check(pcm && n==4 && !g_has_error,"finite buffer conversion succeeds");
        check(pcm && pcm[0]==32767 && pcm[1]==-32767 && pcm[2]==16384 && pcm[3]==-16384,"PCM Q7 clamp then Q4 rounding");
        free(pcm);reset_error();val_decref(b);
    }
    g_try_depth=0;eigs_close(st);
    printf("phase2-gfx-audio-test: %s checks=%d failures=%d\n",boundary_failures?"FAIL":"PASS",boundary_checks,boundary_failures);
    return boundary_failures ? 1 : 0;
}
