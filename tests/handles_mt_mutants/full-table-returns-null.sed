# file: src/builtins.c
# #1146 (3): spawn goes back to returning `null` with no error when the
# 255-slot table is full. The program then "spawns" 300 workers, gets 45
# nulls it never looks at, and exits 0.
/^Value\* builtin_spawn(/,/^}$/ {
  s|^        rt_error(EK_LIMIT, 0,$|        if (0) rt_error(EK_LIMIT, 0,   /* mutant: silent null */|
}
