#!/usr/bin/env bash
# run_probes.sh [--kind pre|tag] [case...]: record observations by
# RUNNING builtins/<case>.eigs on the pre (R1.5 tip) and tag (v0.46.0) binaries.
# Each record is the probe's stdout plus a last line rc=<N> (rc=124 is a
# timeout). stderr is kept beside the scratch copy, never compared. .branch
# files are NEVER written here. No argument: every case in cases.tsv.
#   cases.tsv  case, builtin, hook, stdin   rowmeta.tsv  builtin, closed_in, profile
# A non-release row (profile server|db|zlib) records PENDING-PROFILE unless
# PRE_BIN_<PROFILE> and TAG_BIN_<PROFILE> name matched builds (ruling A3); each
# such binary must first print profile-ok from builtins/_profiles/<profile>.eigs.
# --check <tag-binary> <branch-binary> [case...] compares observations without
# modifying records. R16_LANDED is supplied by make_table.py's shared parser;
# BRANCH_BIN_<PROFILE> and TAG_BIN_<PROFILE> name capability builds.
# DATABASE_URL passes through for db rows. B6's one-request loopback capture
# fixture is started for each http_post process, before the binary starts.
# A hook case runs with ../observation_hooks.c, built here, as
# LD_PRELOAD, and must log "hook-loaded <hook>" (ruling A4).
# Exit 2 on any instrument failure.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
PRE=${PRE_BIN:-$ROOT/build/release/eigenscript}
TAG=${TAG_BIN:-}
CHECK=0
KINDS=(pre tag)
if [ "${1:-}" = --check ]; then
    [ "$#" -ge 3 ] || { echo 'FAIL: --check needs tag and branch binaries'; exit 2; }
    CHECK=1; TAG=$2; BRANCH=$3; shift 3
elif [ "${1:-}" = --kind ]; then
    case "${2:-}" in pre|tag) KINDS=("$2"); shift 2 ;; *) echo 'FAIL: --kind must be pre or tag'; exit 2 ;; esac
fi
START_DIR=$PWD
absolute_binary() { case "$1" in /*) printf '%s\n' "$1" ;; *) printf '%s/%s\n' "$START_DIR" "$1" ;; esac; }
PRE=$(absolute_binary "$PRE")
[ -z "$TAG" ] || TAG=$(absolute_binary "$TAG")
if [ "$CHECK" -eq 1 ]; then BRANCH=$(absolute_binary "$BRANCH"); fi
WORK=${TMPDIR:-/tmp}
ERRDIR=${PROBE_STDERR_DIR:-$WORK/r16bar-stderr}
if [ "$CHECK" -eq 1 ]; then binaries=("$TAG" "$BRANCH")
else binaries=(); for k in "${KINDS[@]}"; do if [ "$k" = pre ]; then binaries+=("$PRE"); else binaries+=("$TAG"); fi; done; fi
for b in "${binaries[@]}"; do [ -x "$b" ] || { echo "FAIL: binary not executable: $b"; exit 2; }; done
mkdir -p "$ERRDIR" || exit 2
SCRATCH=$(mktemp -d "$WORK/r16bar.XXXXXX") || exit 2
SHIM="$SCRATCH/observation-hooks.so"
CAPTURE_PID=
cleanup() { [ -z "$CAPTURE_PID" ] || { kill "$CAPTURE_PID" 2>/dev/null || :; wait "$CAPTURE_PID" 2>/dev/null || :; }; rm -rf "$SCRATCH"; }
trap cleanup EXIT
gcc -shared -fPIC -O0 -Wall -Wextra -Werror "$HERE/../observation_hooks.c" -ldl -o "$SHIM" \
    || { echo "FAIL: the observation shim did not build"; exit 2; }
declare -A HOOK STDIN BUILTIN PROFILE CLOSED ROUND CHECKED
while IFS=$'\t' read -r c b h s; do BUILTIN[$c]=$b; HOOK[$c]=$h; STDIN[$c]=$s; done < <(tail -n +2 "$HERE/cases.tsv")
while IFS=$'\t' read -r b ci p; do PROFILE[$b]=$p; CLOSED[$b]=$ci; done < <(tail -n +2 "$HERE/rowmeta.tsv")
while IFS=$'\t' read -r b file class loss q7 round rest; do ROUND[$b]=$round; done < <(tail -n +2 "$HERE/builtins.tsv")
[ ${#BUILTIN[@]} -gt 0 ] && [ ${#PROFILE[@]} -gt 0 ] || { echo "FAIL: empty cases.tsv or rowmeta.tsv"; exit 2; }
cd "$HERE/builtins" || exit 2
names=("$@")
[ ${#names[@]} -gt 0 ] || names=($(printf '%s\n' "${!BUILTIN[@]}" | LC_ALL=C sort))
bad=0; pending=0; hooked=0
FIXENV=()
[ -z "${DATABASE_URL:-}" ] || FIXENV+=("DATABASE_URL=$DATABASE_URL")

profile_ok() {  # profile_ok <binary> <profile>: the binary carries the profile's capabilities
    local tmp out rc key="$1|$2"
    [ "${CHECKED[$key]:-}" != yes ] || return 0
    tmp=$(mktemp -d "$WORK/r16profile.XXXXXX") || exit 2
    out=$( ( ulimit -v 1500000; cd "$tmp" && exec env -i PATH=/usr/bin:/bin HOME="$tmp" "${FIXENV[@]}" \
        timeout 60 "$1" "$HERE/builtins/_profiles/$2.eigs" </dev/null 2>/dev/null ) )
    rc=$?
    rm -rf "$tmp"
    if [ "$rc" -eq 0 ] && grep -qx 'profile-ok' <<<"$out"; then CHECKED[$key]=yes; return 0; fi
    return 1
}
run_one() {  # run_one <binary> <case> <kind: pre|tag>
    local c=$2 kind=$3 out="$HERE/builtins/$2.$3" tmp rc hook=${HOOK[$2]} in=/dev/null expected capture_rc=0
    if [ "$CHECK" -eq 1 ]; then out="$SCRATCH/$2.$3"; fi
    rm -f "$out"   # a stale record must never survive a run that did not write one
    tmp=$(mktemp -d "$WORK/r16probe.XXXXXX") || exit 2
    [ "${STDIN[$c]}" = "-" ] || in="$HERE/builtins/_stdin/${STDIN[$c]}"
    [ -r "$in" ] || { echo "FAIL: $c: no stdin fixture $in"; bad=$((bad + 1)); rm -rf "$tmp"; return; }
    local -a hookenv=()   # set after timeout, so only the probed binary loads the shim
    [ "$hook" = "-" ] || hookenv=(LD_PRELOAD="$SHIM" R16_HOOK="$hook" R16_HOOK_LOG="$tmp/hook.log")
    local -a captureenv=()
    if [ "${BUILTIN[$c]}" = http_post ]; then
        python3 "$HERE/http_capture.py" "$tmp/capture.url" "$tmp/capture.request" >"$tmp/capture.stdout" 2>"$tmp/capture.stderr" &
        CAPTURE_PID=$!
        for ((attempt=0; attempt<100; attempt++)); do [ ! -s "$tmp/capture.url" ] || break; sleep 0.02; done
        if [ ! -s "$tmp/capture.url" ]; then
            echo "FAIL: $c.$kind capture fixture did not start"; cat "$tmp/capture.stderr"; bad=$((bad + 1))
            kill "$CAPTURE_PID" 2>/dev/null || :; wait "$CAPTURE_PID" 2>/dev/null || :; CAPTURE_PID=
            rm -rf "$tmp"; return
        fi
        captureenv=("R16_HTTP_CAPTURE_URL=$(cat "$tmp/capture.url")")
    fi
    # The suite's headless gfx/audio conditions (SDL dummy drivers), the local
    # display, the bitmap font for deterministic text metrics, a memory cap.
    ( ulimit -v 1500000; cd "$tmp" && exec env -i PATH=/usr/bin:/bin HOME="$tmp" \
        DISPLAY=:99 SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy \
        EIGS_GFX_FONT=/nonexistent/eigs-no-font.ttf EIGS_PROBE_TMP="$tmp" "${FIXENV[@]}" "${captureenv[@]}" \
        timeout 60 env "${hookenv[@]}" "$1" "$HERE/builtins/$c.eigs" <"$in" >"$out" 2>"$ERRDIR/$c.$kind.stderr" )
    rc=$?
    # Every probe prints at least one line, so an empty stdout with rc 0 is an
    # instrument failure (it was one: a relative path written after the cd).
    if [ ! -s "$out" ] && [ "$rc" -eq 0 ]; then echo "FAIL: $c.$kind printed nothing with rc 0"; bad=$((bad + 1)); fi
    # No probe may block on any binary (values are queued first), so a timeout is a named failure.
    if [ "$rc" -eq 124 ]; then echo "FAIL: $c.$kind timed out (rc 124)"; bad=$((bad + 1)); fi
    if [ "$hook" != "-" ]; then
        if head -1 "$tmp/hook.log" 2>/dev/null | grep -qx "hook-loaded $hook"; then hooked=$((hooked + 1))
        else echo "FAIL: $c.$kind ran without its hook $hook (no hook-loaded line)"; bad=$((bad + 1)); fi
    fi
    echo "rc=$rc" >> "$out"
    # Optional evidence export from this exact gate run; never an expectation.
    if [ "$CHECK" -eq 1 ] && [ -n "${PROBE_OBSERVATIONS_DIR:-}" ]; then
        mkdir -p "$PROBE_OBSERVATIONS_DIR" || exit 2
        cp "$out" "$PROBE_OBSERVATIONS_DIR/$c.$kind" || exit 2
    fi
    if [ -n "$CAPTURE_PID" ]; then
        # A failed request must not leave a fixture waiting for its one client.
        if [ ! -f "$tmp/capture.request" ]; then kill "$CAPTURE_PID" 2>/dev/null || :; fi
        wait "$CAPTURE_PID"; capture_rc=$?; CAPTURE_PID=
        if [ "$capture_rc" -ne 0 ]; then
            echo "FAIL: $c.$kind capture fixture failed (rc $capture_rc)"; cat "$tmp/capture.stderr"
            if [ -f "$tmp/capture.request" ]; then echo "HTTP request:"; cat "$tmp/capture.request"; echo; fi
            bad=$((bad + 1))
        fi
    fi
    if [ "$CHECK" -eq 1 ]; then
        expected=tag
        if [ "$kind" = branch ]; then
            expected=pre
            case " ${R16_LANDED:-} " in *" R1.6${ROUND[${BUILTIN[$c]}]} "*) expected=branch ;; esac
            # D5: an R1.7 closure is live as soon as R1.7 is declared,
            # independently of the row's original R1.6 migration group.
            if [ "${CLOSED[${BUILTIN[$c]}]}" = R1.7 ]; then
                case " ${R16_LANDED:-} " in *" R1.7 "*) expected=branch ;; esac
            fi
        fi
        if ! cmp -s "$out" "$HERE/builtins/$c.$expected"; then
            echo "FAIL: ${BUILTIN[$c]}: $c.$kind differs from .$expected"
            diff -u "$HERE/builtins/$c.$expected" "$out" || :
            if [ -f "$tmp/capture.request" ]; then echo "HTTP request:"; cat "$tmp/capture.request"; echo; fi
            bad=$((bad + 1))
        fi
    fi
    rm -rf "$tmp"
}
ran=0
for c in "${names[@]}"; do
    [ -n "${BUILTIN[$c]:-}" ] || { echo "FAIL: $c is not a case in cases.tsv"; exit 2; }
    [ -f "$c.eigs" ] || { echo "FAIL: no probe builtins/$c.eigs"; exit 2; }
    p=${PROFILE[${BUILTIN[$c]}]:-}
    if [ "$CHECK" -eq 1 ]; then kinds=(tag branch); else kinds=("${KINDS[@]}"); fi
    for k in "${kinds[@]}"; do
        case "$k" in pre) binary=$PRE ;; tag) binary=$TAG ;; branch) binary=$BRANCH ;; esac
        case "$p" in
            release) run_one "$binary" "$c" "$k" ;;
            server|db|zlib)
                u=${p^^}; var=${k^^}_BIN_$u
                if [ -n "${!var:-}" ]; then binary=$(absolute_binary "${!var}");
                elif [ "$CHECK" -ne 1 ]; then
                    printf 'PENDING-PROFILE %s\n' "$p" > "$c.$k"; pending=$((pending + 1)); continue
                fi
                [ -x "$binary" ] || { echo "FAIL: binary not executable: $binary"; exit 2; }
                profile_ok "$binary" "$p" || { echo "FAIL: $binary is not a $p build (builtins/_profiles/$p.eigs did not print profile-ok)"; exit 2; }
                run_one "$binary" "$c" "$k" ;;
            *) echo "FAIL: $c: unknown profile '$p'"; exit 2 ;;
        esac
    done
    ran=$((ran + 1))
done
echo "ran=$ran requested=${#names[@]} empty_or_hookless=$bad hook_runs=$hooked pending_profile=$pending"
[ "$ran" -eq "${#names[@]}" ] && [ "$bad" -eq 0 ] || exit 2
