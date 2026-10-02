#!/bin/bash
# Core must not include an extension private header (#744). ext_db_internal.h
# pulls <libpq-fe.h>; a core include makes every EXT_DB=1 build need PostgreSQL
# headers, and only `make full` compiles that. Leg A scans Makefile SOURCES
# against tree headers (exemptions both ways). Leg B compiles each core TU
# with every extension ON and a poisoned <libpq-fe.h>.
set -uo pipefail
WERROR_FLAGS_FILE="$(dirname "$0")/werror_flags.txt"
. "$(dirname "$0")/read_werror_flags.sh" || exit 1
cd "$(dirname "$0")/.." || exit 1
EXEMPT="builtins.c:ext_net_internal.h"
hdrs=$(ls src/ext_*_internal.h src/model_internal.h 2>/dev/null | sed 's#^src/##' | sort -u)
tus=$(make --no-print-directory print-SOURCES 2>/dev/null | tr ' ' '\n' | sed -n 's#^src/##p' | grep '\.c$' | sort -u)
if [ -z "$hdrs" ] || [ -z "$tus" ]; then echo "FAIL[A]: enumerated 0 headers or 0 core TUs (matcher broke)" >&2; exit 1; fi
n_scanned=0; n_hits=0; seen=""; rc=0
for tu in $tus; do
    [ -f "src/$tu" ] || continue
    n_scanned=$((n_scanned + 1))
    for h in $hdrs; do
        [ "$h" = "${tu%.c}_internal.h" ] && continue
        grep -qE "^[[:space:]]*#[[:space:]]*include[[:space:]]+\"$h\"" "src/$tu" || continue
        n_hits=$((n_hits + 1)); pair="$tu:$h"
        case " $EXEMPT " in
            *" $pair "*) seen="$seen $pair" ;;
            *) echo "FAIL[A]: core TU src/$tu includes extension private header \"$h\"" >&2
               echo "         declare the entry point in src/ext_register.h instead" >&2; rc=1 ;;
        esac
    done
done
for e in $EXEMPT; do
    case " $seen " in *" $e "*) ;; *) echo "FAIL[A]: pinned exemption '$e' matches nothing — drop it" >&2; rc=1 ;; esac
done
[ "$rc" = 0 ] && echo "leg A: $n_scanned core TUs scanned, $n_hits ext-private include(s), all pinned"
poison=$(mktemp -d)
work="$poison/results"
mkdir "$work"
printf '%s\n' '#error "core TU reached <libpq-fe.h> (#744): the core must not include ext_db_internal.h"' > "$poison/libpq-fe.h"
jobs=${CORE_EXT_JOBS:-2}
case "$jobs" in *[!0-9]*|'') echo "FAIL[B]: CORE_EXT_JOBS must be a positive integer" >&2; rm -rf "$poison"; exit 2 ;; esac
[ "$jobs" -gt 0 ] || { echo "FAIL[B]: CORE_EXT_JOBS must be a positive integer" >&2; rm -rf "$poison"; exit 2; }
cc=${CC:-gcc}
compile_tu() {
    _n=$1 _tu=$2
    "$cc" -c -o /dev/null -I"$poison" -Isrc -Wall $WERROR_FLAGS -Werror=implicit-function-declaration \
        -DEIGENSCRIPT_EXT_HTTP=1 -DEIGENSCRIPT_EXT_MODEL=1 -DEIGENSCRIPT_EXT_DB=1 -DEIGENSCRIPT_EXT_NET=1 \
        -DEIGENSCRIPT_VERSION='"gate"' "src/$_tu" > "$work/$_n.out" 2>&1
    echo "$?" > "$work/$_n.status"
}
n=0; running=0; pids=""
for tu in $tus; do
    [ -f "src/$tu" ] || continue
    n=$((n + 1))
    printf '%s\n' "$tu" > "$work/$n.tu"
    compile_tu "$n" "$tu" & pids="$pids $!"; running=$((running + 1))
    if [ "$running" -eq "$jobs" ]; then
        for pid in $pids; do wait "$pid"; done
        running=0; pids=""
    fi
done
for pid in $pids; do wait "$pid"; done

brc=0; i=1
while [ "$i" -le "$n" ]; do
    tu=$(cat "$work/$i.tu")
    st=$(cat "$work/$i.status")
    if [ "$st" != 0 ]; then
        echo "FAIL[B]: src/$tu does not compile with every extension ON and libpq poisoned" >&2
        head -6 "$work/$i.out" >&2
        brc=1
    fi
    i=$((i + 1))
done
rm -rf "$poison"
if [ "$n" -lt 10 ]; then echo "FAIL[B]: only $n core TUs probed (matcher broke)" >&2; brc=1; fi
[ "$brc" = 0 ] && echo "leg B: $n core TUs compile with EXT_{HTTP,MODEL,DB,NET}=1 and <libpq-fe.h> poisoned"
if [ "$rc" = 0 ] && [ "$brc" = 0 ]; then echo "OK: no core -> extension-private include edge"; exit 0; fi
exit 1
