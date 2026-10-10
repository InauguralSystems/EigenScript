#!/usr/bin/env bash
# container_access_check.sh: keep runtime Value LIST/DICT element storage behind
# src/container.h (#1665 arm D step 1). Step 2 changes the storage behind that
# API in one place, so a raw `data.list.items` / `data.dict.vals` access anywhere
# else is a site step 2 would silently miss. Prints one verdict line:
#   container-access: examined=<hits> allowed=<n> violations=<n>
# examined counts every raw hit outside container.h, so a vacuous run (zero
# hits because the scan found no files) is distinguishable from a clean one.
set -euo pipefail
cd "$(dirname "$0")/.."
examined=0 allowed=0 violations=0
while IFS= read -r hit; do
    [[ -z $hit ]] && continue
    examined=$((examined + 1))
    file=${hit%%:*}; rest=${hit#*:}; line=${rest%%:*}; text=${rest#*:}
    case "$file" in
        src/parser.c|src/compiler.c|src/lint.c|src/eigenlsp.c|src/lint_host.c)
            # ASTNode owns its own data.dict.vals array; not a Value container.
            allowed=$((allowed + 1)); continue ;;
    esac
    case "$file:$text" in
        src/jit.c:*'offsetof(Value, data.dict.vals)'*)
            # Emitted machine code needs the representation offset (step-2 site).
            allowed=$((allowed + 1)); continue ;;
        src/eigenscript.h:*'arg->data.list.items[i]'*)
            # eigs_bool_gate scans arg lists before container.h is included
            # (step-2 site: it must test the slot tag, not a Value*).
            allowed=$((allowed + 1)); continue ;;
    esac
    printf 'raw Value container access: %s:%s:%s\n' "$file" "$line" "$text" >&2
    violations=$((violations + 1))
done < <(LC_ALL=C grep -n -E 'data\.list\.items|data\.dict\.vals' src/*.c src/*.h \
         | grep -v '^src/container\.h:' || true)
echo "container-access: examined=$examined allowed=$allowed violations=$violations"
if (( violations )); then
    echo 'Use the accessor API in src/container.h.' >&2
    exit 1
fi
(( examined > 0 )) || { echo 'container-access: scan found nothing (vacuous)' >&2; exit 1; }
