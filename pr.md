# Verification evidence for #1192

Both measurements below used the source at `e8c126936eae8a52723bdd0f7d7243db69fa76cb`
on the same x86-64 Ubuntu host with Valgrind 3.22.0.

## Exact `strlen` mutant (`EIGS_STR_LEN_CHECK`)

```console
$ make clean
$ make -j2 CFLAGS='-Wall -Wextra -Werror=implicit-function-declaration -O2 -fstack-protector-strong -D_FORTIFY_SOURCE=2 -fPIE -DEIGS_STR_LEN_CHECK'
$ EIGS="$PWD/src/eigenscript" bash tests/test_string_len_complexity.sh
string-len-complexity: short(1000) Ir=85810542 long(8000) Ir=113624232 ratio=1.324 max=1.25
RED: len of string instruction cost grows with string length (ratio 1.324 > 1.25)
$ echo $?
1
```

## Unmodified release build of the same commit

```console
$ make clean
$ make -j2
$ EIGS="$PWD/src/eigenscript" bash tests/test_string_len_complexity.sh
string-len-complexity: short(1000) Ir=78910551 long(8000) Ir=79424241 ratio=1.007 max=1.25
PASS: len of string has constant instruction cost
$ echo $?
0
```
