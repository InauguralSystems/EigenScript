echo "[18j] Dict field cache after a removal tombstone (#2146)"
check_eigs_suite "a cache hit on a removed key is a miss, for get, set and the numeric rewrite" test_dict_tombstone_cache_2146.eigs "Fail: 0"
