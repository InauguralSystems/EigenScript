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

# Files declared migrated may use only the slot API.  Count forbidden calls
# independently so an empty B0 list is an explicit, non-vacuous population.
migrated_files=0
migrated_hits=0
migrated_violations=0
while IFS= read -r file; do
    case "$file" in ''|'#'*) continue ;; esac
    migrated_files=$((migrated_files + 1))
    if [[ ! -f $file ]]; then
        echo "container-migrated: missing listed file: $file" >&2
        migrated_violations=$((migrated_violations + 1))
        continue
    fi
    while IFS= read -r hit; do
        [[ -z $hit ]] && continue
        migrated_hits=$((migrated_hits + 1))
        echo "forbidden migrated container access: $file:$hit" >&2
        migrated_violations=$((migrated_violations + 1))
    done < <(grep -n -E 'list_get_borrow[[:space:]]*[(]|dict_value_get_borrow[[:space:]]*[(]|(^|[^[:alnum:]_])dict_get(_hashed|_cached)?[[:space:]]*[(]|list_values_storage[[:space:]]*[(]' "$file" || true)
done < "${EIGS_CONTAINER_MIGRATED_LIST:-tools/container_migrated_files.txt}"
echo "container-migrated: files=$migrated_files examined=$migrated_hits violations=$migrated_violations"
if (( migrated_violations != 0 )); then
    if [[ ${EIGS_CONTAINER_EXPECT_VIOLATION:-0} == 1 ]]; then
        echo "container-migrated-plant: PASS"
    else
        exit 1
    fi
fi
