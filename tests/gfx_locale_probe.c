#define _GNU_SOURCE
#include <dlfcn.h>
#include <locale.h>
#include <stdio.h>
#include <stdlib.h>

/* LD_PRELOAD probe used by test_gfx_ctype_locale.sh.  It observes the locale
 * selected inside the EigenScript process without adding a test-only builtin
 * to the language runtime. */
char *setlocale(int category, const char *locale) {
    static char *(*real_setlocale)(int, const char *);
    if (!real_setlocale)
        real_setlocale = (char *(*)(int, const char *))dlsym(RTLD_NEXT, "setlocale");

    char *result = real_setlocale(category, locale);
    const char *path = getenv("EIGS_LOCALE_PROBE");
    if (path && category == LC_CTYPE && locale) {
        FILE *out = fopen(path, "a");
        if (out) {
            fprintf(out, "%s -> %s\n", locale, result ? result : "<failed>");
            fclose(out);
        }
    }
    return result;
}
