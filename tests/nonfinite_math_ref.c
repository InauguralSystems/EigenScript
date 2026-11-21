/* Independent libm/IEEE oracle for #2444. Input: name a b c count.
 * Decimal output round-trips the result; the driver applies the language's
 * shortest-round-trip spelling before comparing the printed answer. */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(void) {
    char name[32], aa[32], bb[32], cc[32];
    int count;
    while (scanf("%31s %31s %31s %31s %d", name, aa, bb, cc, &count) == 5) {
        double a = strtod(aa, NULL), b = strtod(bb, NULL), c = strtod(cc, NULL), r;
#define UNARY(n, expression) if (strcmp(name, n) == 0) r = (expression)
#define NEXT(n, expression) else UNARY(n, expression)
        UNARY("abs", fabs(a));
        NEXT("negative", -a);
        NEXT("floor", floor(a));
        NEXT("ceil", ceil(a));
        NEXT("round", round(a));
        NEXT("fround", (double)(float)a);
        NEXT("sqrt", sqrt(a));
        NEXT("exp", exp(a));
        NEXT("log", log(a));
        NEXT("sin", sin(a));
        NEXT("cos", cos(a));
        NEXT("tan", tan(a));
        NEXT("asin", asin(a));
        NEXT("acos", acos(a));
        NEXT("atan", atan(a));
        NEXT("atan2", atan2(a, b));
        NEXT("pow", pow(a, b));
        NEXT("add", a + b);
        NEXT("subtract", a - b);
        NEXT("multiply", a * b);
        NEXT("divide", a / b);
        else if (strcmp(name, "sum") == 0 || strcmp(name, "mean") == 0) {
            r = 0.0;
            r += a; r += b;
            if (count == 3) r += c;
            if (strcmp(name, "mean") == 0) r /= count;
        } else if (strcmp(name, "norm") == 0) {
            r = 0.0;
            r += a * a; r += b * b;
            if (count == 3) r += c * c;
            r = sqrt(r);
        } else return 2;
        if (isnan(r)) printf("nan");
        else printf("%.17g", r);
        printf("\t%d\t%d\t0\n", !!isinf(r), !!isnan(r));
    }
    return ferror(stdin) ? 1 : 0;
}
