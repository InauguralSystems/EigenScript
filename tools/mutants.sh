#!/usr/bin/env bash
# Manual mutation trains: bash tools/mutants.sh <train> [mutant] | --selftest [train|all].
# Configs contain the ordered population, commands, bounds and lane accounting.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
fail() { echo "FAIL: $*" >&2; return 2; }
TMO=$(command -v timeout || command -v gtimeout) || { fail 'timeout is required'; exit 2; }

load_train() {
    TRAIN=$1
    case "$TRAIN" in ''|*[!a-z_]*) fail "unknown train $TRAIN"; return 2;; esac
    MUTDIR="$ROOT/tests/${TRAIN}_mutants"
    [ -f "$MUTDIR/train.conf" ] || { fail "unknown train $TRAIN"; return 2; }
    BUILD=release BUILD_GOAL=build RUNS=10 STYLE=count FAIL_MODE=all DEFAULT_TARGET=''
    # Guard empty optional arrays at expansion sites for Bash 3.2 + nounset.
    ORACLE_ENV=() ORACLES=() COMPLETED=() MUTANTS=() WITNESSES=()
    LINK_SOURCE='' LINK_BINARY='' ORACLE_SEPARATOR=''
    TSAN_RUNS=3
    source "$MUTDIR/train.conf"
    ORACLE_TIMEOUT=${MUTANT_ORACLE_TIMEOUT:-$ORACLE_TIMEOUT}
    SCRATCH="$ROOT/build/mutants/$TRAIN"
    mkdir -p "$SCRATCH"
    LABEL=$(printf '%s_MUTANTS' "$TRAIN" | tr '[:lower:]' '[:upper:]')
}

population() {
    local f name bad=0 disk=() controls=(comment-only-equivalent oracle-abort)
    for f in "$MUTDIR"/*.sed "$MUTDIR"/*.patch; do
        [ -f "$f" ] || continue
        name=${f##*/}; disk+=("${name%.*}")
    done
    [ "${#MUTANTS[@]}" -gt 0 ] || { fail "$TRAIN: empty declared population"; return 2; }
    [ "${#disk[@]}" -gt 0 ] || { fail "$TRAIN: empty on-disk population"; return 2; }
    printf '%s\n' "${MUTANTS[@]}" "${controls[@]}" | LC_ALL=C sort > "$SCRATCH/declared"
    printf '%s\n' "${disk[@]}" | LC_ALL=C sort > "$SCRATCH/disk"
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        fail "$name: declared/on-disk mismatch or duplicate" || true
        bad=1
    done < <({ LC_ALL=C comm -3 "$SCRATCH/declared" "$SCRATCH/disk"; uniq -d "$SCRATCH/declared"; uniq -d "$SCRATCH/disk"; } | sed 's/^[[:space:]]*//')
    [ "$bad" -eq 0 ]
}

copy_tree() {
    local dest=$1
    rm -rf "$dest"
    mkdir -p "$dest"
    rsync -a --exclude '.git' --exclude build --exclude '.build-evidence' \
        --exclude 'tests/__pycache__' --exclude '.grok' "$ROOT/" "$dest/" || return 2
    mkdir -p "$dest/build/$BUILD"
    cp -a "$ROOT/build/$BUILD/"*.o "$ROOT/build/$BUILD/"*.d "$dest/build/$BUILD/" 2>/dev/null || true
}

apply_mutant() {
    local dest=$1 spec=$2 target f="$MUTDIR/$2" changed=0 targets
    if [ -f "$f.patch" ]; then
        targets=$(sed -n 's|^+++ b/\([^[:space:]]*\).*|\1|p' "$f.patch")
        (cd "$dest" && patch -p1 --forward --batch < "$f.patch" >/dev/null) || { fail "$spec: patch failed"; return 2; }
    else
        target=$(sed -n 's/^# file: //p' "$f.sed" | head -1)
        target=${target:-$DEFAULT_TARGET}
        [ -n "$target" ] || { fail "$spec: no # file: header"; return 2; }
        sed -f "$f.sed" "$dest/$target" > "$dest/$target.mut" && mv "$dest/$target.mut" "$dest/$target" || return 2
        targets=$target
    fi
    for target in $targets; do
        cmp -s "$ROOT/$target" "$dest/$target" || changed=1
    done
    [ "$changed" -eq 1 ] || { fail "$spec: did not change $targets"; return 2; }
}

link_fixture() {
    local dest=$1 variant=$2 SOURCES="$1/$3" binary=$4 obj objs=() flags=(-O2)
    [ "$variant" != tsan ] || flags=(-fsanitize=thread -g -O1)
    for obj in "$dest/build/$variant/"*.o; do
        [ "${obj##*/}" = main.o ] || objs+=("$obj")
    done
    gcc -Werror=switch -Werror=comment -Werror=misleading-indentation "${flags[@]}" \
        -o "$dest/$binary" "$SOURCES" "${objs[@]}" -lm -lpthread -I"$dest/src" -I"$dest/build"
}

build_dest() {
    local dest=$1
    rm -f "$dest/src/eigenscript" "$dest/build/$BUILD/eigenscript"
    make -C "$dest" "$BUILD_GOAL" || return 2
    [ -z "$LINK_SOURCE" ] || link_fixture "$dest" "$BUILD" "$LINK_SOURCE" "$LINK_BINARY"
}

run_oracle() {
    local dest=$1 log=$2 command program path rc=0 step_rc
    : > "$log"
    for command in "${ORACLES[@]}"; do
        read -r program path <<< "$command"
        [ ! -s "$log" ] || [ -z "$ORACLE_SEPARATOR" ] || echo "$ORACLE_SEPARATOR" >> "$log"
        step_rc=0
        EIGS_BIN="$dest/src/eigenscript" env ${ORACLE_ENV[@]+"${ORACLE_ENV[@]}"} \
            "$TMO" -k 5 "$ORACLE_TIMEOUT" "$program" "$dest/$path" >> "$log" 2>&1 || step_rc=$?
        case "$step_rc" in 124|137) echo "$step_rc"; return;; esac
        [ "$rc" -ne 0 ] || rc=$step_rc
    done
    echo "$rc"
}

classify_kill() {
    local log=$1 rc=$2 killed
    case "$rc" in 124|137) echo "hang(no exit in ${ORACLE_TIMEOUT}s)"; return;; esac
    killed=$(LC_ALL=C sed -n 's/^  FAIL: \([^:]*\):.*/\1/p' "$log")
    if [ "$FAIL_MODE" = first ]; then killed=$(printf '%s\n' "$killed" | sed -n '1p')
    else killed=$(printf '%s\n' "$killed" | LC_ALL=C sort -u | paste -sd+ -); fi
    if [ -n "$killed" ]; then echo "$killed"
    elif [ "$rc" -ne 0 ]; then echo "crash(rc=$rc)"
    else return 1; fi
}

oracle_completed() {   # the LAST summary line (same prefix) must match, as the old scripts read it
    local pattern last
    for pattern in "${COMPLETED[@]}"; do
        last=$(grep -E "${pattern%% *}" "$1" | tail -n 1)
        [ -n "$last" ] && grep -Eq "$pattern" <<< "$last" || return 1
    done
}

run_tsan() {
    local dest=$1 spec=$2 stem=$3 fixture=$4 bound=$5 i rc hits=0 log
    make -C "$dest" tsan > "$SCRATCH/$spec.tsanbuild.log" 2>&1 || { echo 0; return; }
    local command=("$dest/src/eigenscript" "$dest/$fixture")
    if [[ "$fixture" = *.c ]]; then
        link_fixture "$dest" tsan "$fixture" build/tsan/witness > "$SCRATCH/$spec.tsanlink.log" 2>&1 || { echo 0; return; }
        command=("$dest/build/tsan/witness")
    fi
    [ -f "$dest/$fixture" ] || { echo 0; return; }
    for ((i=1; i<=TSAN_RUNS; i++)); do
        log="$SCRATCH/$spec.tsan.$i.log"; rc=0
        (cd "$dest/src" && TSAN_OPTIONS='halt_on_error=0 exitcode=0' \
            "$TMO" -k 5 "$bound" setarch -R "${command[@]}") > "$log" 2>&1 || rc=$?
        case "$rc" in 124|137) echo "TSAN $spec: KILLED by hang(no exit in ${bound}s) on run $i" >&2;; esac
        if [ "$rc" -ne 0 ] || grep -q 'WARNING: ThreadSanitizer' "$log"; then hits=$((hits + 1)); fi
    done
    echo "$hits"
}

run_one() {
    local spec=$1 dest="$SCRATCH/$1" i rc reason='' k=0 survived=0 runs=$RUNS control=0
    case "$spec" in comment-only-equivalent|oracle-abort) runs=1; control=1;; esac
    copy_tree "$dest" && apply_mutant "$dest" "$spec" || return 2
    if ! build_dest "$dest" > "$SCRATCH/$spec.build.log" 2>&1 || [ ! -x "$dest/src/eigenscript" ]; then
        fail "$spec: BROKEN build (see $SCRATCH/$spec.build.log)"; return 2
    fi
    for ((i=1; i<=runs; i++)); do
        local log="$SCRATCH/$spec.$i.log"
        rc=$(run_oracle "$dest" "$log")
        if reason=$(classify_kill "$log" "$rc"); then k=$((k + 1))
        elif ! oracle_completed "$log"; then
            echo "MUTANT $spec: BROKEN on run $i — oracle rc=$rc with no FAIL line and no completion marker"; return 2
        else survived=1; break; fi
    done
    if [ "$control" -eq 1 ]; then   # each control has ONE right answer; anything else is a broken train
        if [ "$survived" -eq 0 ]; then
            echo "MUTANT $spec: KILLED by $reason"
            case "$spec:$reason" in oracle-abort:crash\(rc=*) return 0;; esac
            fail "$spec: control must be KILLED by crash(rc=...), got '$reason'"; return 2
        fi
        echo "MUTANT $spec: SURVIVED (oracle completed, no FAIL line)"
        [ "$spec" = comment-only-equivalent ] && return 1
        fail "$spec: control must be KILLED by crash, but SURVIVED"; return 2
    fi
    local row mutant stem='' fixture bound hits=0 note
    for row in ${WITNESSES[@]+"${WITNESSES[@]}"}; do
        read -r mutant stem fixture bound <<< "$row"
        if [ "$mutant" = "$spec" ]; then hits=$(run_tsan "$dest" "$spec" "$stem" "$fixture" "$bound"); break; fi
        stem=''
    done
    if [ "$STYLE" = lanes ]; then
        note='[no tsan witness declared — see the header]'
        if [ -n "$stem" ]; then
            if [ "$hits" -ge "$TSAN_RUNS" ]; then note="tsan:$stem ($TSAN_RUNS/$TSAN_RUNS)"
            else note="tsan:$stem $hits/$TSAN_RUNS — STRUCTURAL-ONLY on that lane"; fi
        fi
        reason="$reason ($k/$runs)"
        [ "$survived" -eq 0 ] || reason="release lane SURVIVED ($k/$runs before run $i)"
        if [ "$survived" -eq 0 ] || [ "$hits" -ge "$TSAN_RUNS" ]; then echo "MUTANT $spec: KILLED by $reason + $note"; return 0; fi
        echo "MUTANT $spec: SURVIVED — $reason + $note"; return 1
    fi
    if [ "$survived" -eq 1 ]; then
        note=" on run $i"; [ "$STYLE" != single ] || note=''
        echo "MUTANT $spec: SURVIVED$note (oracle rc=$rc, no FAIL line)"; return 1
    fi
    note=" ($k/$runs)"; [ "$STYLE" != single ] || note=''
    echo "MUTANT $spec: KILLED by $reason$note"
}

selftest() (   # $1 = train whose two controls are asserted (default dict_keys, the fastest)
    load_train "${1:-dict_keys}"
    population
    local log="$SCRATCH/selftest.log" rc spec
    for spec in oracle-abort comment-only-equivalent; do
        rc=0; run_one "$spec" > "$log" 2>&1 || rc=$?
        cat "$log"
        case "$spec:$rc" in
            oracle-abort:0) grep -q '^MUTANT oracle-abort: KILLED by crash(rc=' "$log";;
            comment-only-equivalent:1) grep -q '^MUTANT comment-only-equivalent: SURVIVED (oracle completed, no FAIL line)$' "$log";;
            *) fail "selftest $spec: unexpected rc=$rc"; exit 2;;
        esac
        echo "SELFTEST $spec: verdict + completion/crash check verified"
    done
    local original=$MUTDIR
    MUTDIR=$(mktemp -d "$SCRATCH/selftest-mutants.XXXXXX")
    trap 'rm -rf "$MUTDIR"' EXIT
    cp -a "$original/." "$MUTDIR/"
    printf '# file: src/eigenscript.c\n' > "$MUTDIR/planted-no-change.sed"
    MUTANTS+=(planted-no-change)
    population
    rc=0; run_one planted-no-change > "$log" 2>&1 || rc=$?
    [ "$rc" -eq 2 ] || exit 2
    grep -q '^FAIL: planted-no-change: did not change ' "$log"
    cat "$log"; echo 'SELFTEST planted-no-change: apply_mutant went red'
    rm "$MUTDIR/planted-no-change.sed"
    rc=0; population > "$log" 2>&1 || rc=$?
    [ "$rc" -ne 0 ] || exit 2
    grep -q '^FAIL: planted-no-change: declared/on-disk mismatch' "$log"
    cat "$log"; echo 'SELFTEST declared-only planted-no-change: population went red'
    cp "$MUTDIR/comment-only-equivalent.sed" "$MUTDIR/planted-disk-only.sed"
    MUTANTS=("${MUTANTS[@]:0:${#MUTANTS[@]}-1}")
    rc=0; population > "$log" 2>&1 || rc=$?
    [ "$rc" -ne 0 ] || exit 2
    grep -q '^FAIL: planted-disk-only: declared/on-disk mismatch' "$log"
    cat "$log"; echo 'SELFTEST on-disk-only planted-disk-only: population went red'
    echo 'MUTANTS_SELFTEST: all checks passed'
)

if [ "${1:-}" = --selftest ]; then
    if [ "${2:-}" = all ]; then
        for f in "$ROOT"/tests/*_mutants/train.conf; do t=${f%_mutants/train.conf}; selftest "${t##*/}" || exit 2; done; exit 0
    fi
    selftest "${2:-}"; exit
fi
[ "$#" -ge 1 ] && [ "$#" -le 2 ] || { fail "usage: $0 <train> [mutant] | --selftest [train|all]"; exit 2; }
load_train "$1"
population || exit 2
if [ "$#" -eq 2 ]; then
    grep -Fxq -- "$2" "$SCRATCH/declared" || { fail "unknown mutant $2"; exit 2; }
    run_one "$2"; exit
fi
failed=0; examined=0
for spec in "${MUTANTS[@]}"; do run_one "$spec" || failed=1; examined=$((examined + 1)); done
[ "$examined" -eq "${#MUTANTS[@]}" ] && [ "$examined" -gt 0 ] || { fail "$TRAIN: examined $examined/${#MUTANTS[@]}"; exit 2; }
[ "$failed" -eq 0 ] || { echo "$LABEL: survivors remain"; exit 1; }
echo "$LABEL: all killed ($examined/$examined)"
