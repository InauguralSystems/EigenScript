# file: src/trace.c
# A critic's own round-1 mutant: the READER — arm_set_has, the site the whole
# guard exists for — drops its hold while every other site keeps one. It took
# the file-wide lock-site count 7 -> 6 and SURVIVED 10/10 against the old
# floor row (`>= 6`), with `ARMING_MT: 9 passed, 0 failed` every run. The
# per-site row now names the site.
/^static int arm_set_has(const char \*name) {$/,/^}$/ {
    s|^    arm_lock();$|    (void)0;|
    s|^    arm_unlock();$|    (void)0;|
}
