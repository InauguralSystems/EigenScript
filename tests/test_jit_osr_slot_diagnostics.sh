#!/usr/bin/env bash
set -u
EIGS=${EIGS:-$(cd "$(dirname "$0")/../src" && pwd)/eigenscript}
fixture=$(cd "$(dirname "$0")" && pwd)/test_jit_osr_slots.eigs

check_dump() {
    awk '
      /^\[jit\] / { if (match($0, /cache_full_rejects=[0-9]+/)) { x=substr($0,RSTART,RLENGTH); sub(/.*=/,"",x); rejects=x+0 } }
      $2 ~ /^[0-9]+$/ && ($3=="yes" || $3=="no" || $3=="full" || $3=="?") {
        rows++; if ($3=="full") shown++; shown += $15+0
        slots += $13+0
      }
      END { exit !(rows>0 && slots>=2 && rejects>0 && shown==rejects) }
    '
}

if [ "${1:-}" = "--selftest" ]; then
    control='[jit] scanned=3 compiled=1 cache_used=1 cache_full_rejects=2
<module> 1 yes 100.0% RET 20 100.0% 20 full 0 0 <end> 3 0 1
helper 1 full 1.0% 0 10 0.0% 0 ? 0 0 <cache-full> 0 0 0'
    if printf '%s\n' "$control" | check_dump; then
        echo '  PASS: complete-slot clean control reconciles'
    else
        echo '  FAIL: complete-slot clean control was rejected'; exit 1
    fi
    planted=$(printf '%s\n' "$control" | sed 's/<end> 3 0 1/<end> 1 0 0/')
    if printf '%s\n' "$planted" | check_dump; then
        echo '  FAIL: omitted nonzero OSR slot escaped the guard'; exit 1
    else
        echo '  PASS: omitted nonzero OSR slot turns the guard red'
    fi
    exit 0
fi

out=$(EIGS_JIT_CACHE_PAGES=1 EIGS_JIT_OSR_THRESHOLD=1 EIGS_JIT_STATS=1 EIGS_JIT_HOT=1 \
    "$EIGS" "$fixture" 2>&1 >/dev/null)
rc=$?
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | check_dump; then
    echo 'PASS: all OSR-slot cache rejections reconcile with the hot dump'
else
    echo "FAIL: OSR-slot hot diagnostic mismatch (rc=$rc)"
    printf '%s\n' "$out"
    exit 1
fi
