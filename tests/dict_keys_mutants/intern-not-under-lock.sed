# file: src/eigenscript.c
# Remove the process-global table's mutex. Two workers can then lose a list
# node to a concurrent push and can hand out two different pointers for one
# key string.
#
# NO behavioural kill is expected and none is claimed: every lookup falls
# back to strcmp and no reader walks the buckets outside the lock, so the
# damage is a lost/duplicated ENTRY (a leak), not a wrong answer — there is
# no output a release run can be wrong about. The class is closed BY
# CONSTRUCTION instead, and the `construction:` rows in
# tests/test_dict_keys_mt.sh kill this deterministically: one lock, one
# unlock per exit, one writer of the bucket array.
s|pthread_mutex_lock(&g_shared_key_mutex);|((void)0);|
s|pthread_mutex_unlock(&g_shared_key_mutex);|((void)0);|
