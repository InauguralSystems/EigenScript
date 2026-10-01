# Verification evidence for #1192

Both measurements below used the source at `40f6a82dac0613472f1b12c7f005ad6de68a9361`
on the same x86-64 Ubuntu host with Valgrind 3.22.0.

## Exact `builtin_len` `strlen` mutant

```console
$ python3 - <<'PY'
from pathlib import Path

path = Path("src/builtins.c")
source = path.read_text()
old = "return make_num(val_str_len(arg));"
new = "return make_num(strlen(arg->data.strv.ptr));"
assert source.count(old) == 1
path.write_text(source.replace(old, new))
PY
$ git diff -- src/builtins.c
@@ -473,7 +473,7 @@ Value* builtin_len(Value *arg) {
     if (arg->type == VAL_LIST)
         return make_num(arg->data.list.count);
     if (arg->type == VAL_STR)
-        return make_num(val_str_len(arg));
+        return make_num(strlen(arg->data.strv.ptr));
$ make -j2
$ EIGS="$PWD/src/eigenscript" bash tests/test_string_len_complexity.sh
string-len-complexity: short(1000) Ir=85210551 long(8000) Ir=113024241 ratio=1.326 max=1.25
RED: len of string instruction cost grows with string length (ratio 1.326 > 1.25)
$ echo $?
1
```

This mutation changes only the `VAL_STR` arm of `builtin_len`; unlike
`EIGS_STR_LEN_CHECK`, it does not add `strlen` calls to other cached-length
reads.

## Unmodified release build of the same commit

```console
$ git checkout -- src/builtins.c
$ make -j2
$ EIGS="$PWD/src/eigenscript" bash tests/test_string_len_complexity.sh
string-len-complexity: short(1000) Ir=78910551 long(8000) Ir=79424241 ratio=1.007 max=1.25
PASS: len of string has constant instruction cost
$ echo $?
0
```
