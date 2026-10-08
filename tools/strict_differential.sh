#!/usr/bin/env bash
# strict_differential.sh — one argument-guard differential.
#
# Subject binary: ./src/eigenscript, or EIGS_DIFF_NEW. Optional baseline
# argument is the other binary. --no-baseline skips only identical-when-off
# and says so. Without either, the run is incomplete and exits 1.
#
# Halves, in order:
#   raises-under-strict     EIGS_STRICT=1, nonzero, and the row's expect
#                           substring (default "<name>: expected")
#   guarded-name cross-check  names derived from ARG_GUARD / ARG_GUARD_TAPED /
#                           ARG_GUARD_PRETAKE / STRICT_REQUIRE / STRICT_DOMAIN /
#                           num_guard_named; a guarded name with no probe fails
#   pins                    documented answers must not raise under strict
#   unset-equals-strict     #1361: strict is the DEFAULT, so every probe row
#                           (and every pixel row) run with EIGS_STRICT UNSET
#                           must equal its EIGS_STRICT=1 run: stdout+stderr+rc.
#                           Needs no baseline, so it runs in suite [99s] too.
#   identical-when-off      baseline vs subject under an explicit EIGS_STRICT=0
#                           ("off" is the opt-out since #1361, not the unset
#                           default), stdout+stderr+rc; valid-input rows in all
#                           three modes (unset, 0, 1) when a baseline is given
#   gfx container-shape sweep   ext_gfx.c want-strings, wrong containers
#   gfx pixel differential  canvas digests and source coverage. Every pixel
#                           row is compared with the flag off; a flag-off
#                           canvas change is a difference, with no waiver.
#   binary-held-still       cksum+size+mtime of the subject (and baseline)
# --common-capabilities <baseline> explicitly permits a baseline without a
# newly implemented extension, or with unbound names replaced by unavailable
# stubs. Such rows are checked separately and NEVER counted as byte-identical.
# Losing an implementation or an existing unavailable binding still fails.
# A build without gfx builtins prints one line, "SKIP: not a gfx build",
# and does not treat the gfx halves as a pass.
#
#   bash tools/strict_differential.sh <baseline-binary>
#   bash tools/strict_differential.sh --no-baseline
#   bash tools/strict_differential.sh --shapes-only --no-baseline
set -uo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"

SHAPES_ONLY=0
if [ "${1:-}" = --shapes-only ]; then SHAPES_ONLY=1; shift; fi
NEW="${EIGS_DIFF_NEW:-./src/eigenscript}"
BASE="${1:-}"
NO_BASELINE=0
COMMON_CAPABILITIES=0
if [ "$BASE" = "--common-capabilities" ]; then
    COMMON_CAPABILITIES=1; BASE="${2:-}"
    [ -n "$BASE" ] && [ "$#" = 2 ] && [[ "$BASE" != --* ]] || { echo 'usage: strict_differential.sh --common-capabilities <baseline>'; exit 2; }
fi
if [ "$BASE" = "--no-baseline" ]; then NO_BASELINE=1; BASE=""; fi
export SDL_VIDEODRIVER="${SDL_VIDEODRIVER:-dummy}"
export SDL_AUDIODRIVER="${SDL_AUDIODRIVER:-dummy}"
# Derive platform here, before any capability or backend capture; no env override.
SHAPE_BACKEND_PLATFORM=$(uname -s) || exit 1

# Matchers are bash case-globs: no pipe, so pipefail cannot invert a match.
# Bodies are pinned byte-for-byte (tools/pipefail_verdict_check.sh).
str_has()      { case "$1" in *"$2"*) return 0 ;; esac; return 1 ; }
str_has_line() { case $'\n'"$1"$'\n' in *$'\n'"$2"$'\n'*) return 0 ;; esac; return 1 ; }
str_has_word() { case " $1 " in *" $2 "*) return 0 ;; esac; return 1 ; }

. tests/lsan_classify.sh
shape_canonical() { # exact owned prefix only; call AFTER raw classification
    local prefix="$2/" marker='@OWNED@/'
    printf '%s' "${1//"$prefix"/$marker}"
}

# ASan reserves a large virtual shadow mapping. The local ordinary GFX cap
# must not become a portable sanitizer limit. Inspect the actual executable;
# neither ASAN_OPTIONS nor a filename is evidence of instrumentation.
shape_asan_symbols() {
    printf '%s\n' "$1" | awk '$NF ~ /^_?__asan_init(@.*)?$/ { found=1 } END { exit !found }'
}
shape_binary_instrumentation() {
    local symbols
    if symbols=$(readelf --wide --syms "$1" 2>/dev/null) ||
       symbols=$(nm "$1" 2>/dev/null); then
        if shape_asan_symbols "$symbols"; then echo asan; else echo ordinary; fi
    else
        echo "FAIL: cannot inspect GFX executable instrumentation: $1" >&2
        return 1
    fi
}
shape_gfx_limit() { # called only in the individual GFX child subshell
    local instrumentation
    if [ "$1" = "$NEW" ]; then instrumentation=$NEW_SHAPE_INSTRUMENTATION
    elif [ -n "$BASE" ] && [ "$1" = "$BASE" ]; then instrumentation=$BASE_SHAPE_INSTRUMENTATION
    else echo 'FAIL: unrecognized GFX executable' >&2; return 125; fi
    case "$SHAPE_BACKEND_PLATFORM" in
        Linux|Darwin) ;;
        *) echo 'FAIL: unsupported GFX address-space platform' >&2; return 125 ;;
    esac
    case "$instrumentation" in
        ordinary)
            # This machine's required Linux ceiling is not a Darwin limit:
            # XNU rejects a ceiling below mappings already owned by the shell.
            if [ "$SHAPE_BACKEND_PLATFORM" = Linux ]; then
                ulimit -v 1500000 || return 125
            fi ;;
        asan)
            [ "$(ulimit -v)" = unlimited ] || {
                echo 'FAIL: instrumented GFX requires an uncapped parent virtual address space' >&2
                return 125
            } ;;
        *) echo 'FAIL: unknown GFX executable instrumentation' >&2; return 125 ;;
    esac
}

cap_observation_ok() { # diagnostic prefix, capability, exact observed state
    case "$3" in implemented|unavailable|undefined) return 0 ;; esac
    echo "  ${1}CAPABILITY DID NOT MEASURE: $2 — $3"
    return 1
}

shape_capture() { # binary, mode, fixture, cap; parent owns the process deadline
    local raw owned="${3%/*}" output child_rc
    if [ -f "$owned/http-context" ]; then
        output=$(bash tests/test_http_server.sh --strict-shape "$1" "$2" "$3" 2>&1); child_rc=$?
        raw=$(printf '%s\n%s' "$child_rc" "$output")
    elif [ -f "$owned/stdin-context" ]; then
        raw=$(run_capture "$1" "$2" "$3" < "$owned/stdin-context")
    elif [ "$4" = gfx ]; then
        raw=$(shape_gfx_limit "$1" || exit 125; run_capture "$1" "$2" "$3")
    else
        raw=$(run_capture "$1" "$2" "$3")
    fi
    printf '%s\n' "$raw" > "$owned/capture.raw"
    if shape_receipt_ok "$raw"; then
        shape_canonical "$raw" "$owned"
    else
        printf '%s' "$raw"
    fi
}
shape_receipt_ok() { # captured rc+output; exact exit plus canonical sanitizer veto
    [ "${1%%$'\n'*}" = 0 ] && [ "$(lsan_classify_name "${1#*$'\n'}")" = none ]
}
shape_done() { shape_receipt_ok "$1" && str_has_line "$1" shape-complete; }
shape_positive_ok() {
    if [ "$2" = 1 ]; then [ "$1" = $'0\nexit-entered' ]
    else shape_done "$1"; fi
}
shape_abort() {
    shape_fail=$((shape_fail + 1)); rc=1
    echo "  FAIL shape: $1 — $2: $(clip "$3" 180)"
}


# Backend presence differs from compiled GFX: bitmap text metrics work without
# SDL. Only exact documented missing-library receipts qualify, currently on
# Darwin. Linux owns provisioned device positives and refuses missing libraries.
shape_backend_classify() { # kind, captured rc+output, actual platform
    shape_receipt_ok "$2" || return 1
    case "$1" in sdl|mixer) ;; *) return 1 ;; esac
    if [ "$2" = $'0\nshape-backend: true' ]; then echo present; return 0; fi
    [ "$3" = Darwin ] || return 1
    if [ "$1" = sdl ] && [ "$2" = $'0\ngfx_open: cannot load libSDL2\nshape-backend: false' ]; then
        echo absent-sdl; return 0
    fi
    if [ "$1" = mixer ] && [ "$2" = $'0\naudio_music: cannot load libSDL2_mixer (install libsdl2-mixer-2.0-0)\nshape-backend: false' ]; then
        echo absent-mixer; return 0
    fi
    return 1
}
shape_backend_probe() { # binary, subject/baseline, kind
    local mode got found state=""
    for mode in - 0 1; do
        got=$(shape_gfx_limit "$1" || exit 125; run_capture "$1" "$mode" "$TMP/shapes/backend/$3.eigs")
        printf '%s\n' "$got" > "$TMP/shapes/backend/$2-$3-$mode.raw"
        found=$(shape_backend_classify "$3" "$got" "$SHAPE_BACKEND_PLATFORM") || {
            echo "FAIL: $2 $3 backend dependency: $(clip "$got" 180)" >&2
            return 1
        }
        if [ -n "$state" ] && [ "$state" != "$found" ]; then
            echo "FAIL: $2 $3 backend modes disagree" >&2; return 1
        fi
        state=$found
    done
    printf '%s\n' "$state"
}
shape_backend_prepare() { # binary, subject/baseline, kind; lazy per-binary cache
    local key="$2-$3" state
    case "$key" in
        subject-sdl) state=$SHAPE_SUBJECT_SDL ;;
        subject-mixer) state=$SHAPE_SUBJECT_MIXER ;;
        baseline-sdl) state=$SHAPE_BASELINE_SDL ;;
        baseline-mixer) state=$SHAPE_BASELINE_MIXER ;;
        *) return 1 ;;
    esac
    if [ "$state" = unmeasured ]; then
        if [ "$3" = mixer ]; then
            shape_backend_prepare "$1" "$2" sdl || return 1
            if [ "$SHAPE_BACKEND_STATE" = absent-sdl ]; then state=absent-sdl; fi
        fi
        if [ "$state" = unmeasured ]; then state=$(shape_backend_probe "$1" "$2" "$3") || return 1; fi
        case "$key" in
            subject-sdl) SHAPE_SUBJECT_SDL=$state ;;
            subject-mixer) SHAPE_SUBJECT_MIXER=$state ;;
            baseline-sdl) SHAPE_BASELINE_SDL=$state ;;
            baseline-mixer) SHAPE_BASELINE_MIXER=$state ;;
        esac
        echo "  BACKEND $2 $3: $state"
    fi
    SHAPE_BACKEND_STATE=$state
}
shape_typed_positive_ok() { # unchanged positive oracle, or exact absence oracle
    shape_positive_ok "$1" "$2" || return 1
    [ -z "$3" ] || [ "$1" = "$3" ]
}


shape_selftest() {
    local passed=0 failed=0 saved
    shape_case() {
        local label="$1" expected="$2" capture="$3" actual=1
        shape_done "$capture" && actual=0
        if [ "$actual" = "$expected" ]; then
            echo "  PASS: $label"; passed=$((passed + 1))
        else
            echo "  FAIL: $label"; failed=$((failed + 1))
        fi
    }
    shape_case 'healthy completed receipt' 0 $'0\nshape-complete'
    shape_case 'ordinary nonzero' 1 $'1\nshape-complete'
    shape_case 'timeout is not success' 1 $'124\nshape-complete'
    shape_case 'signal is not success' 1 $'139\nshape-complete'
    shape_case 'missing completion' 1 $'0\nordinary output'
    shape_case 'ASan text with zero rc' 1 $'0\nERROR: AddressSanitizer: synthetic ordinary classifier control\nshape-complete'
    shape_case 'LSan text with zero rc' 1 $'0\nERROR: LeakSanitizer: detected memory leaks\nshape-complete'
    shape_case 'UBSan text with zero rc' 1 $'0\nfixture.c:1: runtime error: synthetic classifier control\nshape-complete'
    shape_case 'discussion text is not a diagnostic' 0 $'0\nThis fixture discusses AddressSanitizer checks.\nshape-complete'
    shape_case 'completion substring is not a line' 1 $'0\nnot-shape-complete'
    saved=$(declare -f shape_receipt_ok)
    # Private function-only calibration: inert captured text, no product fault.
    shape_receipt_ok() { [ "${1%%$'\n'*}" = 0 ]; }
    shape_case 'removed sanitizer veto admits ASan (expected RED)' 0 $'0\nERROR: AddressSanitizer: synthetic classifier control\nshape-complete'
    shape_case 'removed sanitizer veto admits LSan (expected RED)' 0 $'0\nERROR: LeakSanitizer: detected memory leaks\nshape-complete'
    eval "$saved"
    shape_case 'restored sanitizer veto rejects capture' 1 $'0\nERROR: AddressSanitizer: synthetic classifier control\nshape-complete'
    shape_case 'owned-prefix canonicalization matches' 0 "$(
        a=$(shape_canonical $'0\nWritten /owned/a/data\nshape-complete' /owned/a)
        b=$(shape_canonical $'0\nWritten /owned/b/data\nshape-complete' /owned/b)
        [ "$a" = "$b" ] && printf '0\nshape-complete' || printf '1\nmismatch')"
    shape_case 'unowned lookalike path difference retained' 0 "$(
        a=$(shape_canonical $'0\nRead /owned/a-other\nshape-complete' /owned/a)
        b=$(shape_canonical $'0\nRead /owned/b-other\nshape-complete' /owned/b)
        [ "$a" != "$b" ] && printf '0\nshape-complete' || printf '1\nmasked')"
    shape_case 'owned path sanitizer capture still fails' 1 $'0\nERROR: AddressSanitizer: synthetic /owned/a/data\nshape-complete'

    shape_case 'ELF ASan init symbol recognized' 0 "$(
        shape_asan_symbols '  7: 000000 0 FUNC GLOBAL DEFAULT UND __asan_init' && printf '0\nshape-complete' || printf '1\nmissed')"
    shape_case 'Mach-O ASan init symbol recognized' 0 "$(
        shape_asan_symbols '                 U ___asan_init' && printf '0\nshape-complete' || printf '1\nmissed')"
    shape_case 'symbol substring is not instrumentation' 0 "$(
        shape_asan_symbols '0000 T fake__asan_init_suffix' && printf '1\nfalse positive' || printf '0\nshape-complete')"
    shape_case 'ordinary symbols remain ordinary' 0 "$(
        shape_asan_symbols '0000 T main' && printf '1\nfalse positive' || printf '0\nshape-complete')"
    shape_case 'ordinary GFX child follows the actual platform policy' 0 "$(
        NEW_SHAPE_INSTRUMENTATION=ordinary
        before_soft=$(ulimit -Sv); before_hard=$(ulimit -Hv)
        shape_gfx_limit "$NEW" || exit 1
        if [ "$SHAPE_BACKEND_PLATFORM" = Linux ]; then
            [ "$(ulimit -Sv)" = 1500000 ] && [ "$(ulimit -Hv)" = 1500000 ] || exit 1
        elif [ "$SHAPE_BACKEND_PLATFORM" = Darwin ]; then
            [ "$(ulimit -Sv)" = "$before_soft" ] && [ "$(ulimit -Hv)" = "$before_hard" ] || exit 1
        else
            exit 1
        fi
        printf '0\nshape-complete')"
    shape_case 'verified ASan child keeps unlimited mapping space' 0 "$(
        NEW_SHAPE_INSTRUMENTATION=asan
        shape_gfx_limit "$NEW" && [ "$(ulimit -v)" = unlimited ] && printf '0\nshape-complete' || printf '1\nwrong limit')"
    shape_case 'already capped ASan parent refuses before execution' 0 "$(
        NEW_SHAPE_INSTRUMENTATION=asan
        # Inert inherited-limit query: portable even where lowering RLIMIT_AS fails.
        ulimit() { [ "$*" = '-v' ] || return 1; echo 1500000; }
        shape_gfx_limit "$NEW" 2>/dev/null; actual=$?
        [ "$actual" = 125 ] && printf '0\nshape-complete' || printf '1\naccepted cap')"
    shape_case 'unknown instrumentation refuses before execution' 0 "$(
        NEW_SHAPE_INSTRUMENTATION=unknown
        shape_gfx_limit "$NEW" 2>/dev/null; actual=$?
        [ "$actual" = 125 ] && printf '0\nshape-complete' || printf '1\naccepted unknown')"
    saved=$(declare -f shape_gfx_limit)
    shape_gfx_limit() { ulimit -v 1500000; }
    shape_case 'restored old unconditional cap breaks ASan oracle (expected RED)' 1 "$(
        NEW_SHAPE_INSTRUMENTATION=asan; virtual_limit=unlimited
        ulimit() {
            if [ "$*" = '-v 1500000' ]; then
                virtual_limit=1500000
            elif [ "$*" = '-v' ]; then
                echo "$virtual_limit"
            else
                return 1
            fi
        }
        shape_gfx_limit "$NEW" && [ "$(ulimit -v)" = unlimited ] && printf '0\nshape-complete' || printf '1\nwrong limit')"
    eval "$saved"
    shape_case 'restored instrumentation branch preserves mapping space' 0 "$(
        NEW_SHAPE_INSTRUMENTATION=asan
        shape_gfx_limit "$NEW" && [ "$(ulimit -v)" = unlimited ] && printf '0\nshape-complete' || printf '1\nwrong limit')"
    # Inert policy controls call the actual functions; no runtime/device child.
    shape_case 'Darwin ordinary makes no virtual-limit setter call' 0 "$(
        SHAPE_BACKEND_PLATFORM=Darwin; NEW_SHAPE_INSTRUMENTATION=ordinary; called=0
        ulimit() { called=1; return 1; }
        shape_gfx_limit "$NEW" && [ "$called" = 0 ] && printf '0\nshape-complete' || printf '1\nsetter called')"
    shape_case 'Darwin baseline ordinary also preserves inherited limits' 0 "$(
        SHAPE_BACKEND_PLATFORM=Darwin; BASE=/shape-baseline; BASE_SHAPE_INSTRUMENTATION=ordinary; called=0
        ulimit() { called=1; return 1; }
        shape_gfx_limit "$BASE" && [ "$called" = 0 ] && printf '0\nshape-complete' || printf '1\nsetter called')"
    shape_case 'Linux cap failure stops before a child' 0 "$(
        SHAPE_BACKEND_PLATFORM=Linux; NEW_SHAPE_INSTRUMENTATION=ordinary
        ulimit() { return 1; }
        got=$(shape_gfx_limit "$NEW" || exit 125; printf child-ran); actual=$?
        [ "$actual" = 125 ] && [ -z "$got" ] && printf '0\nshape-complete' || printf '1\nchild or failure lost')"
    shape_case 'unknown platform stops before a child' 0 "$(
        SHAPE_BACKEND_PLATFORM=Unknown; NEW_SHAPE_INSTRUMENTATION=ordinary
        got=$(shape_gfx_limit "$NEW" 2>/dev/null || exit 125; printf child-ran); actual=$?
        [ "$actual" = 125 ] && [ -z "$got" ] && printf '0\nshape-complete' || printf '1\nunknown accepted')"
    shape_case 'Darwin inherited ASan cap still refuses' 0 "$(
        SHAPE_BACKEND_PLATFORM=Darwin; NEW_SHAPE_INSTRUMENTATION=asan
        ulimit() { [ "$*" = '-v' ] || return 1; echo 1500000; }
        shape_gfx_limit "$NEW" 2>/dev/null; actual=$?
        [ "$actual" = 125 ] && printf '0\nshape-complete' || printf '1\nASan cap accepted')"
    shape_case 'unknown platform also refuses instrumented executable' 0 "$(
        SHAPE_BACKEND_PLATFORM=Unknown; NEW_SHAPE_INSTRUMENTATION=asan
        shape_gfx_limit "$NEW" 2>/dev/null; actual=$?
        [ "$actual" = 125 ] && printf '0\nshape-complete' || printf '1\nunknown accepted')"
    shape_case 'implemented capability observation is valid' 0 "$(
        cap_observation_ok '' gfx implemented && printf '0\nshape-complete' || printf '1\nrejected')"
    shape_case 'documented unavailable observation remains valid' 0 "$(
        cap_observation_ok '' model unavailable && printf '0\nshape-complete' || printf '1\nrejected')"
    shape_case 'undefined observation remains explicit' 0 "$(
        cap_observation_ok 'BASELINE ' gfx undefined && printf '0\nshape-complete' || printf '1\nrejected')"
    shape_case 'invalid subject observation cannot reach absence derivation' 0 "$(
        got=$(cap_observation_ok '' gfx 'invalid: cap failed' >/dev/null || exit 1; printf absent-derived); actual=$?
        [ "$actual" = 1 ] && [ -z "$got" ] && printf '0\nshape-complete' || printf '1\ninvalid accepted')"
    shape_case 'invalid baseline observation cannot reach absence derivation' 0 "$(
        got=$(cap_observation_ok 'BASELINE ' gfx 'invalid: modes disagree' >/dev/null || exit 1; printf absent-derived); actual=$?
        [ "$actual" = 1 ] && [ -z "$got" ] && printf '0\nshape-complete' || printf '1\ninvalid accepted')"
    shape_case 'empty observation cannot reach absence derivation' 0 "$(
        got=$(cap_observation_ok '' gfx '' >/dev/null || exit 1; printf absent-derived); actual=$?
        [ "$actual" = 1 ] && [ -z "$got" ] && printf '0\nshape-complete' || printf '1\nempty accepted')"
    # Inert exact captures from the independently reviewed backend decision table.
    backend_case() {
        local label="$1" expected_rc="$2" expected_stdout="$3" got actual
        got=$(shape_backend_classify "$4" "$5" "$6"); actual=$?
        if [ "$actual" = "$expected_rc" ] && [ "$got" = "$expected_stdout" ]; then
            echo "  PASS: backend $label"; passed=$((passed + 1))
        else
            echo "  FAIL: backend $label (rc=$actual state=$got)"; failed=$((failed + 1))
        fi
    }
    backend_case sdl-present-Darwin 0 present sdl '0
shape-backend: true' Darwin
    backend_case sdl-present-Linux 0 present sdl '0
shape-backend: true' Linux
    backend_case sdl-exact-absent-Darwin 0 absent-sdl sdl '0
gfx_open: cannot load libSDL2
shape-backend: false' Darwin
    backend_case sdl-absence-Linux-is-failure 1 '' sdl '0
gfx_open: cannot load libSDL2
shape-backend: false' Linux
    backend_case sdl-other-backend-diagnostic 1 '' sdl '0
audio_music: cannot load libSDL2_mixer (install libsdl2-mixer-2.0-0)
shape-backend: false' Darwin
    backend_case sdl-wrong-child-rc-1 1 '' sdl '1
gfx_open: cannot load libSDL2
shape-backend: false' Darwin
    backend_case sdl-wrong-child-rc-3 1 '' sdl '3
gfx_open: cannot load libSDL2
shape-backend: false' Darwin
    backend_case sdl-wrong-child-rc-124 1 '' sdl '124
gfx_open: cannot load libSDL2
shape-backend: false' Darwin
    backend_case sdl-wrong-child-rc--9 1 '' sdl '-9
gfx_open: cannot load libSDL2
shape-backend: false' Darwin
    backend_case sdl-altered-diagnostic 1 '' sdl '0
gfx_open: cannot load libSDL2 changed
shape-backend: false' Darwin
    backend_case sdl-unrelated-first-line 1 '' sdl '0
unrelated diagnostic
gfx_open: cannot load libSDL2
shape-backend: false' Darwin
    backend_case sdl-unrelated-last-line 1 '' sdl '0
gfx_open: cannot load libSDL2
shape-backend: false
unrelated diagnostic' Darwin
    backend_case sdl-duplicate-diagnostic 1 '' sdl '0
gfx_open: cannot load libSDL2
gfx_open: cannot load libSDL2
shape-backend: false' Darwin
    backend_case sdl-arbitrary-zero 1 '' sdl '0
shape-backend: false' Darwin
    backend_case sdl-success-with-absence-diagnostic 1 '' sdl '0
gfx_open: cannot load libSDL2
shape-backend: true' Darwin
    backend_case sdl-wrong-result-marker 1 '' sdl '0
gfx_open: cannot load libSDL2
shape-backend: 2' Darwin
    backend_case sdl-missing-child-rc 1 '' sdl 'gfx_open: cannot load libSDL2
shape-backend: false' Darwin
    backend_case sdl-duplicate-result-marker 1 '' sdl '0
gfx_open: cannot load libSDL2
shape-backend: false
shape-backend: false' Darwin
    backend_case sdl-missing-result-marker 1 '' sdl '0
gfx_open: cannot load libSDL2' Darwin
    backend_case sdl-asan-veto 1 '' sdl '0
gfx_open: cannot load libSDL2
ERROR: AddressSanitizer: inert classifier text
shape-backend: false' Darwin
    backend_case sdl-lsan-veto 1 '' sdl '0
gfx_open: cannot load libSDL2
ERROR: LeakSanitizer: detected memory leaks
shape-backend: false' Darwin
    backend_case sdl-ubsan-veto 1 '' sdl '0
gfx_open: cannot load libSDL2
runtime error: inert classifier text
shape-backend: false' Darwin
    backend_case sdl-tsan-veto 1 '' sdl '0
gfx_open: cannot load libSDL2
WARNING: ThreadSanitizer: data race (inert text only)
shape-backend: false' Darwin
    backend_case mixer-present-Darwin 0 present mixer '0
shape-backend: true' Darwin
    backend_case mixer-present-Linux 0 present mixer '0
shape-backend: true' Linux
    backend_case mixer-exact-absent-Darwin 0 absent-mixer mixer '0
audio_music: cannot load libSDL2_mixer (install libsdl2-mixer-2.0-0)
shape-backend: false' Darwin
    backend_case mixer-absence-Linux-is-failure 1 '' mixer '0
audio_music: cannot load libSDL2_mixer (install libsdl2-mixer-2.0-0)
shape-backend: false' Linux
    backend_case mixer-other-backend-diagnostic 1 '' mixer '0
gfx_open: cannot load libSDL2
shape-backend: false' Darwin
    backend_case mixer-wrong-child-rc-1 1 '' mixer '1
audio_music: cannot load libSDL2_mixer (install libsdl2-mixer-2.0-0)
shape-backend: false' Darwin
    backend_case mixer-wrong-child-rc-3 1 '' mixer '3
audio_music: cannot load libSDL2_mixer (install libsdl2-mixer-2.0-0)
shape-backend: false' Darwin
    backend_case mixer-wrong-child-rc-124 1 '' mixer '124
audio_music: cannot load libSDL2_mixer (install libsdl2-mixer-2.0-0)
shape-backend: false' Darwin
    backend_case mixer-wrong-child-rc--9 1 '' mixer '-9
audio_music: cannot load libSDL2_mixer (install libsdl2-mixer-2.0-0)
shape-backend: false' Darwin
    backend_case mixer-altered-diagnostic 1 '' mixer '0
audio_music: cannot load libSDL2_mixer (install libsdl2-mixer-2.0-0) changed
shape-backend: false' Darwin
    backend_case mixer-unrelated-first-line 1 '' mixer '0
unrelated diagnostic
audio_music: cannot load libSDL2_mixer (install libsdl2-mixer-2.0-0)
shape-backend: false' Darwin
    backend_case mixer-unrelated-last-line 1 '' mixer '0
audio_music: cannot load libSDL2_mixer (install libsdl2-mixer-2.0-0)
shape-backend: false
unrelated diagnostic' Darwin
    backend_case mixer-duplicate-diagnostic 1 '' mixer '0
audio_music: cannot load libSDL2_mixer (install libsdl2-mixer-2.0-0)
audio_music: cannot load libSDL2_mixer (install libsdl2-mixer-2.0-0)
shape-backend: false' Darwin
    backend_case mixer-arbitrary-zero 1 '' mixer '0
shape-backend: false' Darwin
    backend_case mixer-success-with-absence-diagnostic 1 '' mixer '0
audio_music: cannot load libSDL2_mixer (install libsdl2-mixer-2.0-0)
shape-backend: true' Darwin
    backend_case mixer-wrong-result-marker 1 '' mixer '0
audio_music: cannot load libSDL2_mixer (install libsdl2-mixer-2.0-0)
shape-backend: 2' Darwin
    backend_case mixer-missing-child-rc 1 '' mixer 'audio_music: cannot load libSDL2_mixer (install libsdl2-mixer-2.0-0)
shape-backend: false' Darwin
    backend_case mixer-duplicate-result-marker 1 '' mixer '0
audio_music: cannot load libSDL2_mixer (install libsdl2-mixer-2.0-0)
shape-backend: false
shape-backend: false' Darwin
    backend_case mixer-missing-result-marker 1 '' mixer '0
audio_music: cannot load libSDL2_mixer (install libsdl2-mixer-2.0-0)' Darwin
    backend_case mixer-asan-veto 1 '' mixer '0
audio_music: cannot load libSDL2_mixer (install libsdl2-mixer-2.0-0)
ERROR: AddressSanitizer: inert classifier text
shape-backend: false' Darwin
    backend_case mixer-lsan-veto 1 '' mixer '0
audio_music: cannot load libSDL2_mixer (install libsdl2-mixer-2.0-0)
ERROR: LeakSanitizer: detected memory leaks
shape-backend: false' Darwin
    backend_case mixer-ubsan-veto 1 '' mixer '0
audio_music: cannot load libSDL2_mixer (install libsdl2-mixer-2.0-0)
runtime error: inert classifier text
shape-backend: false' Darwin
    backend_case mixer-tsan-veto 1 '' mixer '0
audio_music: cannot load libSDL2_mixer (install libsdl2-mixer-2.0-0)
WARNING: ThreadSanitizer: data race (inert text only)
shape-backend: false' Darwin
    backend_case unknown-kind-Darwin 1 '' other '0
shape-backend: true' Darwin
    backend_case unknown-kind-Linux 1 '' other '0
shape-backend: true' Linux
    # Private inert calibration: removing platform ownership admits Linux
    # absence. Restore the actual classifier before the following control.
    saved=$(declare -f shape_backend_classify)
    eval "${saved/shape_backend_classify/shape_backend_original}"
    shape_backend_classify() { shape_backend_original "$1" "$2" Darwin; }
    backend_case 'removed Linux-positive policy is detected (expected RED)' 0 absent-sdl sdl $'0\ngfx_open: cannot load libSDL2\nshape-backend: false' Linux
    eval "$saved"
    unset -f shape_backend_original
    backend_case 'restored Linux-positive policy refuses absence' 1 '' sdl $'0\ngfx_open: cannot load libSDL2\nshape-backend: false' Linux
    echo "SHAPE_CAPTURE_SELFTEST: $passed passed, $failed failed, 88 declared"
    [ "$failed" = 0 ] && [ "$passed" = 88 ]
}
if [ "$BASE" = --selftest ]; then shape_selftest; exit $?; fi

[ -x "$NEW" ] || { echo "FAIL: no built binary at $NEW"; exit 1; }
if [ -z "$BASE" ] && [ "$NO_BASELINE" = 0 ]; then
    echo "FAIL: no baseline binary. Pass one, or --no-baseline to skip identical-when-off."
    exit 1
fi

bin_fingerprint() {
    local f="$1" ck sz mt
    [ -e "$f" ] || { printf ''; return 0; }
    ck=$(cksum "$f" 2>/dev/null) || ck="?"
    if stat -L -c '%s %Y' "$f" >/dev/null 2>&1; then
        read -r sz mt <<<"$(stat -L -c '%s %Y' "$f")"
    else
        read -r sz mt <<<"$(stat -L -f '%z %m' "$f" 2>/dev/null)"
    fi
    printf '%s %s %s' "$ck" "${sz:-?}" "${mt:-?}"
}
FP_NEW_START="$(bin_fingerprint "$NEW")"
FP_BASE_START=""
[ -n "$BASE" ] && FP_BASE_START="$(bin_fingerprint "$BASE")"
NEW_SHAPE_INSTRUMENTATION=$(shape_binary_instrumentation "$NEW") || exit 1
BASE_SHAPE_INSTRUMENTATION=none
if [ -n "$BASE" ]; then BASE_SHAPE_INSTRUMENTATION=$(shape_binary_instrumentation "$BASE") || exit 1; fi
echo "GFX address-space policy: platform=$SHAPE_BACKEND_PLATFORM subject=$NEW_SHAPE_INSTRUMENTATION baseline=$BASE_SHAPE_INSTRUMENTATION (ordinary Linux=1500000 KiB; ordinary Darwin=inherited limits, no imposed address-space cap; ASan=inherited unlimited)"


TMP="$(mktemp -d)"
verdict_printed=0
_sd_main_depth=$BASH_SUBSHELL
_sd_exit() {
    local es=$?
    [ "$BASH_SUBSHELL" = "${_sd_main_depth:-}" ] || return 0
    if [ "${EIGS_DIFF_KEEP_TMP:-0}" = 1 ]; then
        echo "Strict differential raw captures retained: ${TMP:-}"
    else
        rm -rf "${TMP:-}"
    fi
    if [ "${verdict_printed:-0}" != "1" ]; then
        if [ "$es" = "0" ]; then
            echo "  ABORTED: this differential was terminated before printing a verdict."
        else
            echo "  ABORTED: this differential exited (rc=$es) before printing a verdict."
        fi
    fi
}
trap _sd_exit EXIT

# Cheap contract/enrollment check precedes every runtime probe.
if ! python3 tools/strict_shape_contract.py --render "$TMP/shapes"; then
    verdict_printed=1
    exit 1
fi

# Produce one tiny descriptor through the owning normal compiler. The auxiliary
# file target reuses variant objects and never relinks the CLI under this gate.
[ "$NEW" -ef ./src/eigenscript ] || { echo 'FAIL: shape producer requires this checkout owning CLI'; exit 1; }
shape_variant=
for shape_binary in build/*/eigenscript; do
    if [ "$NEW" -ef "$shape_binary" ]; then
        shape_variant=$(basename "$(dirname "$shape_binary")"); break
    fi
done
if [ -z "$shape_variant" ]; then
    shape_variant=release
    echo 'Shape descriptor: build.sh CLI layout; compiler producer uses owning source release objects'
fi
make --no-print-directory "build/$shape_variant/strict_shape_descriptor" "EMBED_OBSERVER_VARIANT=$shape_variant" || exit 1
descriptor_rc=0
"build/$shape_variant/strict_shape_descriptor" > "$TMP/descriptor.json" 2> "$TMP/descriptor.stderr" || descriptor_rc=$?
if [ "$descriptor_rc" != 0 ] || [ -s "$TMP/descriptor.stderr" ] ||
   [ "$(lsan_classify_name "$(cat "$TMP/descriptor.json" "$TMP/descriptor.stderr")")" != none ]; then
    cat "$TMP/descriptor.stderr"; echo 'FAIL: ordinary descriptor producer'; exit 1
fi
python3 - "$TMP" <<'PY' || exit 1
import json, sys
from pathlib import Path
root = Path(sys.argv[1])
descriptor = json.loads((root / 'descriptor.json').read_text())
assert isinstance(descriptor, list) and len(descriptor) == 3
assert descriptor[2] == [42] and 0 < len(descriptor[1]) <= 64
text = json.dumps(descriptor, separators=(',', ':'))
for fixture in (root / 'shapes/sandbox_run').glob('*/*/*/case.eigs'):
    source = fixture.read_text()
    assert source.count('@DESCRIPTOR@') == 1
    fixture.write_text(source.replace('@DESCRIPTOR@', text))
PY

# name|program[|expect]  — wrong-typed call; expect defaults to "<name>: expected"
PROBES=$(cat <<'EOF'
abs|print of (abs of "x")
acos|print of (acos of "x")
asin|print of (asin of "x")
atan|print of (atan of "x")
atan2|print of (atan2 of ["y", 1])
buf_len|print of (buf_len of "x")
ceil|print of (ceil of "x")
char_at|print of (char_at of [42, 0])
contains|print of (contains of [[1, 2, 3], 2])
dict_remove|print of (dict_remove of ([]))
dict_set|print of (dict_set of ([]))
cos|print of (cos of "hello")
dot|print of (dot of [1, 2])
ends_with|print of (ends_with of [42, "x"])
f64_from_bytes|print of (f64_from_bytes of "x")
floor|print of (floor of "x")
gather|print of (gather of ["hello", [0]])
has_key|print of (has_key of [42, "k"])
join|print of (join of [42, ","])
json_path|print of (json_path of 42)
list_contains|print of (list_contains of [42, 1])
max|print of (max of [1, "x", 3])
path_base|print of (path_base of 42)
path_dir|print of (path_dir of 42)
path_ext|print of (path_ext of 42)
path_join|print of (path_join of [42, "b"])
remove_file|print of (remove_file of 42)
rm|print of (rm of 42)
round|print of (round of "x")
secure_equals|print of (secure_equals of [42, "x"])
seed_random|print of (seed_random of "x")
sign_extend|print of (sign_extend of ["x", 8])
sin|print of (sin of "x")
sqrt/exp/log/negative|print of (sqrt of "x")
starts_with|print of (starts_with of [42, "x"])
store_delete|print of (store_delete of [42, "col", "k"])|store_delete: invalid store
index_of|print of (index_of of [42, "x"])
list_index_of|print of (list_index_of of [42, 1])
list_insert_at|print of (list_insert_at of [[1, 2], "i", 9])
list_remove_at|print of (list_remove_at of [[1, 2], "i"])
ord|print of (ord of 42)
exec_capture|print of (exec_capture of 42)
eigen_eval_loss|print of (eigen_eval_loss of ["x", 1])
str_from_bytes|print of (str_from_bytes of 42)
str_lower|print of (str_lower of 42)
str_replace|print of (str_replace of [42, "a", "b"])
str_upper|print of (str_upper of 42)
stream_write|print of (stream_write of "x")
substr|print of (substr of [42, 0, 1])
tan|print of (tan of "x")
task_alive|print of (task_alive of "x")
file_exists|print of (file_exists of 42)
is_dir|print of (is_dir of 42)
is_file|print of (is_file of 42)
read_text|print of (read_text of 42)
read_bytes|print of (read_bytes of 42)
ls|print of (ls of 42)
mkdir|print of (mkdir of 42)
env_get|print of (env_get of 42)
task_kill|print of (task_kill of "x")
task_send|print of (task_send of ["x", 1])
tensor_save|print of (tensor_save of 42)
text_builder_to_string|print of (text_builder_to_string of 42)
trim|print of (trim of 42)
try_parse|print of (try_parse of 42)
write_bytes|print of (write_bytes of 42)
zeros_like|print of (zeros_like of "x")
sum|print of (sum of "hello")
mean|print of (mean of "hello")
norm|print of (norm of "hello")
join|print of (join of [["a", "b"], 42])
rename|print of (rename of [42, "b"])
store_count|print of (store_count of [42, "col"])|store_count: invalid store
store_drop|print of (store_drop of [42, "col"])|store_drop: invalid store
store_update|print of (store_update of [42, "col", "k", {"a": 1}])|store_update: invalid store
store_update|print of (store_update of [(store_open of "@TMP@/probe.db"), "col", ([1, 2]), {"a": 1}])
stream_open|print of (stream_open of [42, 1])
write_text|print of (write_text of [42, "x"])
add/subtract/multiply/divide/pow|print of (add of ["x", 1])
gfx_open|print of (gfx_open of ["800", "600", "t"])
audio_open|print of (audio_open of ["44100", "1"])
audio_capture_open|print of (audio_capture_open of ["44100", "1"])
audio_stream_open|print of (audio_stream_open of ["44100", "1"])
audio_open|print of (audio_open of [44100])
audio_capture_open|print of (audio_capture_open of [44100])
audio_stream_open|print of (audio_stream_open of [48000])
audio_open|print of (audio_open of 44100)
audio_play|print of (audio_play of 42)
audio_stream_push|print of (audio_stream_push of 42)
audio_play_loop|print of (audio_play_loop of [42, 2])
audio_sine|print of (len of (audio_sine of ["440", 0.01, 0.5]))
audio_saw|print of (len of (audio_saw of ["440", 0.01, 0.5]))
audio_square|print of (len of (audio_square of ["440", 0.01, 0.5]))
audio_sweep|print of (len of (audio_sweep of ["100", 200, 0.01, 0.5, 0]))
audio_noise|print of (len of (audio_noise of [0.001, "0.5"]))
audio_envelope|print of (len of (audio_envelope of [([0.1, 0.2]), "0.01", 0.01, 0.5, 0.01]))
audio_gain|print of (len of (audio_gain of [([1.0]), "2.0"]))
json_path|print of (json_path of ["{\"a\": 1e", "a"])|json_path: invalid JSON at position
pow|print of (pow of [0 - 8, 0.5])|pow: result is not a number
num|print of (num of "nan")|num: result is not a number
f64_from_bytes|print of (f64_from_bytes of ([127, 248, 0, 0, 0, 0, 0, 0]))|f64_from_bytes: result is not a number
matmul|local m1 is buffer of [1, 2]\nm1[0] is 1e200\nm1[1] is 1e200\nlocal m2 is buffer of [2, 1]\nm2[0] is 1e200\nm2[1] is 0 - 1e200\nlocal r is matmul of [m1, m2]\nprint of (r[0])|matmul: result is not a number
matmul|print of (matmul of [[[1, "x"]], [[1], [1]]])|matmul: expected a tensor containing only numbers
matmul_at|print of (matmul_at of [[[1, "x"]], [[1, 2]]])|matmul_at: expected a tensor containing only numbers
matmul_bt|print of (matmul_bt of [[[1, "x"]], [[1, 2]]])|matmul_bt: expected a tensor containing only numbers
softmax|print of (softmax of [1, "x"])|softmax: expected a tensor containing only numbers
log_softmax|print of (log_softmax of [1, "x"])|log_softmax: expected a tensor containing only numbers
relu|print of (relu of [1, "x", -2])|relu: expected a tensor containing only numbers
leaky_relu|print of (leaky_relu of [1, "x", -2])|leaky_relu: expected a tensor containing only numbers
tensor_save|print of (tensor_save of [[1, "x"], "@TMP@/bad.tensor"])|tensor_save: expected a tensor containing only numbers
softmax|print of (softmax of ["x", 1])|softmax: expected a tensor containing only numbers
log_softmax|print of (log_softmax of ["x", 1])|log_softmax: expected a tensor containing only numbers
relu|print of (relu of ["x", 1])|relu: expected a tensor containing only numbers
leaky_relu|print of (leaky_relu of ["x", 1])|leaky_relu: expected a tensor containing only numbers
softmax|print of (softmax of [[], ["x"]])|softmax: expected a tensor containing only numbers
log_softmax|print of (log_softmax of [[], ["x"]])|log_softmax: expected a tensor containing only numbers
relu|print of (relu of [[], ["x"]])|relu: expected a tensor containing only numbers
leaky_relu|print of (leaky_relu of [[], ["x"]])|leaky_relu: expected a tensor containing only numbers
tensor_save|print of (tensor_save of [[[], ["x"]], "@TMP@/bad.tensor"])|tensor_save: expected a tensor containing only numbers
tensor_load|write_bytes of ["@TMP@/nan.tensor", [1, 0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 248, 127, 0, 0, 0, 0, 0, 0, 4, 64]]\nprint of (tensor_load of "@TMP@/nan.tensor")|tensor_load: result is not a number
numerical_grad|define bad(_) as:\n    return "bad"\np is [1.0]\nprint of (numerical_grad of [bad, p, 0.001])|numerical_grad: expected loss function to return a number
numerical_grad_rows|define bad(_) as:\n    return "bad"\nm is [[1.0]]\nprint of (numerical_grad_rows of [bad, m, [0], 0.001])|numerical_grad_rows: expected loss function to return a number
numerical_grad_cols|define bad(_) as:\n    return "bad"\nm is [[1.0]]\nprint of (numerical_grad_cols of [bad, m, [0], 0.001])|numerical_grad_cols: expected loss function to return a number
divide|print of (divide of [[1], [0]])|divide: division by zero
split|print of (split of 42)
scan_ints|print of (scan_ints of ({"k": 1}))
scan_int_tokens|print of (scan_int_tokens of ({"k": 1}))
token_name|print of (token_name of "x")
channel_closed|print of (channel_closed of 42)
f64_to_bytes|print of (f64_to_bytes of "x")
buffer|print of (buffer of "x")
json_build|print of (json_build of ({"a": 1}))
sort|print of (sort of ({"a": 1}))
random_int|print of (random_int of ["a", 3])
random_hex|print of (random_hex of "x")
audio_mix|print of (len of (audio_mix of [42, ([0.1])]))
audio_music_play|print of (audio_music_play of [42])
audio_music_volume|print of (audio_music_volume of "loud")
audio_pause|print of (audio_pause of "x")
audio_play_loop|print of (audio_play_loop of [([0.1]), "2"])
audio_stop|print of (audio_stop of "x")
audio_volume|print of (audio_volume of ["1", 1])
gfx_circle|print of (gfx_circle of ["1", 2, 3, 4, 5, 6])
gfx_clear|print of (gfx_clear of ["1", 2, 3])
gfx_clip|print of (gfx_clip of ["1", 2, 3, 4])
gfx_delay|print of (gfx_delay of "5")
gfx_fb|print of (gfx_fb of [42, 4, 4, 0, 0, 1])
gfx_line|print of (gfx_line of ["0", 0, 10, 10, 1, 2, 3])
gfx_point|print of (gfx_point of ["1", 2, 3, 4, 5])
gfx_read|print of (gfx_read of ["1", 1])
gfx_rect|print of (gfx_rect of ["10", 10, 50, 50, 255, 0, 0])
gfx_rrect|print of (gfx_rrect of ["1", 2, 3, 4, 5, 6, 7, 8])
gfx_text|print of (gfx_text of [1, 2, "hi", "255", 0, 0])
gfx_text_height|print of (gfx_text_height of "2")
gfx_text_width|print of (gfx_text_width of 5)
gfx_title|print of (gfx_title of 42)
ppu_render_frame|print of (ppu_render_frame of [1, 2])
EOF
)
PROBES="${PROBES//@TMP@/$TMP}"

# label|program — must exit 0 under EIGS_STRICT=1
PINS=$(cat <<'EOF'
task_alive of an unknown id is 0, not an error|print of (task_alive of 999)
list_contains that finds nothing is 0|print of (list_contains of [[1, 2], 9])
ends_with with a suffix longer than the string is 0|print of (ends_with of ["ab", "abc"])
char_at past the end is ""|print of (char_at of ["ab", 9])
substr starting past the end is ""|print of (substr of ["ab", 9, 1])
join of an empty list is ""|print of (join of [[], ","])
num coerces a list to 0 (documented)|print of (num of ([1, 2]))
try_parse of invalid syntax is 0|print of (try_parse of "!!!")
max of an empty list is 0|print of (max of ([]))
sum of an empty list is 0 (the identity, not a type mistake)|print of (sum of ([]))
mean of an empty list is 0|print of (mean of ([]))
gather of a 1-D tensor in the per-row form is 0 per row (shape, not index)|print of (gather of [[1, 2], [0, 0]])
norm of a real vector still computes|print of (norm of [3, 4])
index_of that finds nothing is -1, not an error|print of (index_of of ["abc", "z"])
list_index_of that finds nothing is -1|print of (list_index_of of [([1, 2]), 9])
ord of the empty string is -1 (no first byte)|print of (ord of "")
sum of a bare number is that number|print of (sum of 7)
join with a real separator still joins|print of (join of [["a", "b"], "-"])
json false decodes to 0|print of (json_path of ["{\"a\": false}", "a"])
json_path of an absent key is "" (no value at that path)|print of f"[{json_path of ["{\"a\": 1}", "b"]}]"
json_path of a JSON null renders as ""|print of f"[{json_path of ["{\"a\": null}", "a"]}]"
file_exists of a real absent path is 0 (#1008 Phase D)|print of (file_exists of "/nonexistent/eigs_971_probe")
is_dir of a real absent path is 0|print of (is_dir of "/nonexistent/eigs_971_probe")
read_text of a real absent path is ""|print of f"[{read_text of "/nonexistent/eigs_971_probe"}]"
index_of miss is -1 even with the flag on|print of (index_of of ["abc", "z"])
num of "inf" saturates (overflow, not NaN)|print of (num of "inf")
pow of a negative base with an INTEGER exponent is defined|print of (pow of [0 - 2, 3])
token_name of an unknown id is "?"|print of (token_name of 9999)
channel_closed of a reclaimed/unknown channel is 1|print of (channel_closed of ({"_channel_id": 99999}))
json_build of null is the empty object|print of (json_build of null)
random_hex of 0 is ""|print of f"[{random_hex of 0}]"
tensor_save preserves a zero-column tensor|assert of [(tensor_save of [[[], []], "@TMP@/zero-cols.tensor"]), "zero-column tensor_save"]
EOF
)
PINS="${PINS//@TMP@/$TMP}"

# programs run on both binaries in both modes when a baseline is given
VALID=$(cat <<'EOF'
print of (sum of [1, 2, 3.5])
print of (mean of [2, 4, 6])
print of (norm of [3, 4])
print of (sum of 7)
print of (max of [1, 5, 3])
print of (file_exists of "..")
print of (is_dir of ".")
print of (is_file of ".")
print of (read_text of "/nonexistent/eigs_1008_probe")
print of (read_bytes of "/nonexistent/eigs_1008_probe")
print of (env_get of "EIGS_1008_UNSET_PROBE")
print of (min of [1, 5, 3])
print of (max of 9)
print of (contains of ["hello", "ell"])
print of (starts_with of ["hello", "he"])
print of (ends_with of ["hello", "lo"])
print of (char_at of ["hello", 1])
print of (char_at of ["hello", 0 - 1])
print of (substr of ["hello", 1, 3])
print of (join of [["a", "b", "c"], "-"])
print of (join of [[], ","])
print of (has_key of [{"k": 1}, "k"])
print of (path_join of ["a", "b"])
print of (atan2 of [1, 1])
print of (list_contains of [[1, 2, 3], 2])
print of (gather of [[[1, 2], [3, 4]], [0, 1]])
print of (str_replace of ["banana", "an", "X"])
print of (add of [[1, 2], [3, 4]])
print of (sqrt of [4, 9])
print of (sign_extend of [255, 8])
print of (seed_random of 42)
print of (try_parse of "x is 1")
print of (num of "42")
print of (num of "0x1f")
print of (json_path of ["{\"a\": {\"b\": 7}}", "a.b"])
print of (task_alive of 1)
print of (str_upper of "abc")
print of (cos of 0)
print of (len of [1, 2, 3])
print of (json_path of ["{\"a\": [1, {\"b\": \"x\"}]}", "a.1.b"])
print of (pow of [2, 10])
print of (pow of [[1, 2, 3], 2])
print of (num of "3.5e2")
print of (f64_from_bytes of (f64_to_bytes of 42.5))
print of (matmul of [[[1, 2]], [[3], [4]]])
local m1 is buffer of [1, 2]\nm1[0] is 1e200\nm1[1] is 1e200\nlocal m2 is buffer of [2, 1]\nm2[0] is 1e200\nm2[1] is 1e200\nlocal r is matmul of [m1, m2]\nprint of (r[0] > 1e308)
print of (divide of [[6, 8], [2, 4]])
print of (split of ["a,b,c", ","])
print of (split of "x y")
print of (scan_ints of "1 2 -3")
print of (len of (scan_int_tokens of "1 x"))
print of (token_name of 0)
print of (channel_closed of (channel of null))
print of (f64_to_bytes of 1)
print of (len of (buffer of 4))
print of (len of (buffer of [2, 3]))
print of (json_build of ["k", 1])
print of (sort of [3, 1, 2])
seed_random of 7\nprint of (random_int of [1, 1])
print of (len of (random_hex of 4))
print of (gfx_text_width of ["hello", 2])
print of (gfx_text_width of "hello")
print of (gfx_text_height of 3)
print of (gfx_text_height of null)
print of (gfx_rect of [0, 0, 1, 1, 1, 2, 3])
print of (gfx_rect of [0, 0, 1, 1, 1, 2, 3, 128])
print of (gfx_clear of [1, 2, 3])
print of (gfx_clip of null)
print of (gfx_poll of null)
print of (gfx_read of [0, 0])
print of (audio_mix of [[0.5], [0.25, 0.25]])
print of (audio_gain of [[1.0], 0.5])
print of (audio_stop of 1)
print of (audio_volume of [1, 0.5])
print of (audio_open of null)
print of (audio_capture_open of null)
print of (audio_stream_open of null)
print of (audio_open of [44100, 1])
print of (audio_capture_open of [44100, 1])
print of (audio_stream_open of [44100, 1])
print of (audio_play of null)
print of (audio_stream_push of null)
print of (audio_play of [0.1, 0.2])
print of (tensor_save of [[[], []], "@TMP@/zero-cols.tensor"])
EOF
)
VALID="${VALID//@TMP@/$TMP}"

sig_name() {
    case "$1" in
        1) printf 'HUP' ;;  2) printf 'INT' ;;  3) printf 'QUIT' ;;
        6) printf 'ABRT' ;; 8) printf 'FPE' ;;  9) printf 'KILL' ;;
        11) printf 'SEGV' ;; 13) printf 'PIPE' ;; 15) printf 'TERM' ;;
        24) printf 'XCPU' ;; 25) printf 'XFSZ' ;;
        *) printf '%s' "$1" ;;
    esac
}
# Probe programs do not call exit, and the runtime exits 0, 1 or 2, so
# 126/127 and >=128 are "did not run", not a guard verdict.
run_did_not_measure() {
    case "$1" in
        126|127) printf 'the process could not be executed (exit %s)' "$1" ;;
        1[3-9][0-9]|12[89]) printf 'killed by SIG%s (%s = 128+%s) — a crash, not a guard' \
            "$(sig_name "$(( $1 - 128 ))")" "$1" "$(( $1 - 128 ))" ;;
        *) printf '' ;;
    esac
}
run_capture() {   # <binary> <strict-or-dash> <file> -> "rc\noutput"
    local bin="$1" strict="$2" f="$3" out rc
    if [ "$strict" = "-" ]; then out="$(env -u EIGS_STRICT "$bin" "$f" 2>&1)"; rc=$?
    else out="$(EIGS_STRICT="$strict" "$bin" "$f" 2>&1)"; rc=$?; fi
    printf '%s\n%s' "$rc" "$out"
}
clip() { printf '%s' "$1" | tr '\n' ' ' | cut -c1-"${2:-80}"; }

extract_guard_names() {
    awk '
    /(ARG_GUARD(_TAPED|_PRETAKE)?|STRICT_REQUIRE|STRICT_DOMAIN|num_guard_named|numerical_loss)\(/ || /tensor_to_flat\(.*"/ { acc = ""; collecting = 1 }
    collecting { acc = acc $0; if (acc ~ /\);[ \t]*$/ || $0 ~ /\);/) {
        collecting = 0
        n = split(acc, parts, "\"")
        if (n >= 2) print parts[2]
    } }
    ' "$@"
}

# Extension membership comes from the registrar's shared name lists, not a
# prefix guess (HTTP request names include shared_*; GFX includes ppu_*).
CAP_NAMES="$(awk '
    /^#define EIGS_.*_BUILTINS\(X\)/ {
        cap = $2
        sub(/^EIGS_/, "", cap); sub(/_BUILTINS\(X\)$/, "", cap)
        if (cap == "HTTP_REQUEST") cap = "HTTP"
        cap = tolower(cap)
        next
    }
    /^[ \t]*X\(/ {
        name = $0; sub(/^[ \t]*X\(/, "", name); sub(/,.*/, "", name)
        print cap "|" name
    }
' src/ext_names.h)"
[ -n "$CAP_NAMES" ] || { echo 'FAIL: no extension names extracted'; exit 1; }
cap_for_name() {
    local name="${1%%/*}"
    printf '%s\n' "$CAP_NAMES" | awk -F'|' -v n="$name" '$2 == n {print $1; exit}'
}
name_for_program() {
    printf '%s\n' "$CAP_NAMES" | awk -F'|' -v p="$1" '
        p ~ ("(^|[^[:alnum:]_])" $2 "[[:space:]]+of([[:space:]]|$)") {print $2; exit}'
}
cap_message() {
    case "$1" in
        http) echo 'HTTP capability unavailable; use the server profile' ;;
        net) echo 'network capability unavailable; use the server profile' ;;
        db) echo 'database capability unavailable; use the server-db profile' ;;
        model) echo 'model capability unavailable; use the server profile' ;;
        gfx) echo '' ;;
    esac
}
cap_contract() {
    local cap="$1" op name answer message
    case "$cap" in
        http) name=http_route; op='http_route of ["GET", "/strict-capability-probe", "ok"]'; answer='result == "route registered"' ;;
        net) name=net_close; op='net_close of -1'; answer='result == null' ;;
        db) name=db_connect; op='db_connect of null'; answer='(json_path of [result, "status"]) == "no_database"' ;;
        model) name=eigen_model_loaded; op='eigen_model_loaded of null'; answer='result == false' ;;   # #1637: a bool
        gfx) name=gfx_text_width; op='gfx_text_width of ["m", 1]'; answer='(type of result) == "num" and result > 0' ;;
    esac
    message="$(cap_message "$cap")"
    cat <<EOF
try:
    result is $op
    assert of [$answer, "capability operation returned the wrong answer"]
    print of "implemented"
catch capability_error:
    if capability_error.kind == "undefined_name" and capability_error.message == "undefined variable '$name'":
        print of "undefined"
    elif capability_error.kind == "value" and capability_error.message == "$message" and "$message" != "":
        print of "unavailable"
    else:
        assert of [0, "unexpected capability error"]
EOF
}
cap_state() { # exact ordinary-operation observation in all strict modes
    local bin="$1" cap="$2" got state="" mode
    cap_contract "$cap" > "$TMP/cap-$cap.eigs"
    # DB's no-database answer must not depend on the caller's live service.
    local DATABASE_URL=""
    for mode in - 0 1; do
        if [ "$cap" = gfx ]; then
            got="$(shape_gfx_limit "$bin" || exit 125; run_capture "$bin" "$mode" "$TMP/cap-$cap.eigs")"
        else
            got="$(run_capture "$bin" "$mode" "$TMP/cap-$cap.eigs")"
        fi
        case "$got" in
            $'0\nimplemented') got=implemented ;;
            $'0\nundefined') got=undefined ;;
            $'0\nunavailable') got=unavailable ;;
            *) echo "invalid: $(clip "$got" 120)"; return ;;
        esac
        if [ -n "$state" ] && [ "$state" != "$got" ]; then
            echo "invalid: strict modes disagree ($state/$got)"; return
        fi
        state="$got"
    done
    echo "$state"
}
state_for() {
    local states="$NEW_CAPS"
    [ "$1" = baseline ] && states="$BASE_CAPS"
    printf '%s\n' "$states" | awk -F'|' -v c="$2" '$1 == c {print $2; exit}'
}
check_absent_call() { # each omitted row must reach its exact error contract
    local bin="$1" state="$2" cap="$3" name="$4" file="$5" mode got want kind
    if [ "$state" = unavailable ]; then want="$(cap_message "$cap")"; kind=value
    else want="undefined variable '$name'"; kind=undefined_name; fi
    # Observe kind/message through the real catch path: uncaught diagnostics
    # also contain source excerpts/carets, which are not capability verdicts.
    {
        echo 'try:'
        sed 's/^/    /' "$file"
        echo '    assert of [0, "an absent implementation returned normally"]'
        echo 'catch absent_error:'
        printf '    assert of [absent_error.kind == "%s" and absent_error.message == "%s", "wrong absent-call error"]\n' "$kind" "$want"
        printf '    print of "absent:%s"\n' "$name"
    } > "$TMP/absent-call.eigs"
    for mode in - 0 1; do
        got="$(run_capture "$bin" "$mode" "$TMP/absent-call.eigs")"
        if [ "$got" != $'0\n'"absent:$name" ]; then
            echo "  ABSENT CONTRACT FAILED: $name [strict=$mode, $state]: $(clip "$got" 120)"
            return 1
        fi
    done
}

rc=0
n_probe=0; n_ident=0; n_differ=0; n_raise=0; n_silent=0; n_unset_eq=0; unset_list=""
n_pin=0; n_pin_ok=0; n_pin_broke=0; n_misattr=0; n_unrun=0; n_skipped=0
differ_list=""; silent_list=""; pin_list=""; misattr_list=""; unrun_list=""; skipped_list=""
NEW_CAPS=""; BASE_CAPS=""; profile_transitions=""; n_profile_rows=0
for cap in http net db model gfx; do
    ns="$(cap_state "$NEW" "$cap")"
    cap_observation_ok "" "$cap" "$ns" || exit 1
    NEW_CAPS="$NEW_CAPS
$cap|$ns"
    case "$ns" in
        implemented|unavailable) ;;
        undefined) [ "$cap" = gfx ] || { echo "  CAPABILITY BINDING MISSING: $cap"; rc=1; } ;;
    esac
    [ -n "$BASE" ] || continue
    bs="$(cap_state "$BASE" "$cap")"
    cap_observation_ok "BASELINE " "$cap" "$bs" || exit 1
    BASE_CAPS="$BASE_CAPS
$cap|$bs"
    if [ "$bs" != "$ns" ]; then
        profile_transitions="$profile_transitions
    $cap: baseline=$bs subject=$ns"
        # Common-capability mode allows expansion, never removal of a prior
        # implementation or replacement of an unavailable binding by a typo.
        if [ "$COMMON_CAPABILITIES" != 1 ] || [ "$bs" = implemented ] || { [ "$bs" = unavailable ] && [ "$ns" = undefined ]; }; then
            echo "  PROFILE CONTRACT DIFFERS: $cap ($bs -> $ns)"; rc=1
        fi
    fi
done

release_srcs="$(make --no-print-directory print-SRC_V_release 2>/dev/null | tr ' ' '\n' | sed '/^$/d' | sort -u)"
absent_here=""
for cap in http net db model gfx; do
    [ "$(state_for subject "$cap")" = implemented ] && continue
    absent_here="$absent_here $(printf '%s\n' "$CAP_NAMES" | awk -F'|' -v c="$cap" '$1 == c {print $2}' | tr '\n' ' ')"
done
if [ -n "$release_srcs" ]; then
    for f in src/*.c; do
        str_has_line "$release_srcs" "$f" && continue
        f_names="$(extract_guard_names "$f" | sed 's,/.*,,' | sed '/^$/d' | sort -u \
            | grep -vxF -f <(printf '%s\n' "$CAP_NAMES" | cut -d'|' -f2) || true)"
        [ -z "$f_names" ] && continue
        rep="$(printf '%s\n' "$f_names" | head -1)"
        printf 'print of "eigs-probe-ran"\nprint of %s\n' "$rep" > "$TMP/present.eigs"
        _present_out="$("$NEW" "$TMP/present.eigs" 2>&1)"; _present_rc=$?
        _why="$(run_did_not_measure "$_present_rc")"
        if [ -z "$_why" ] && ! str_has "$_present_out" "eigs-probe-ran"; then
            _why="the probe printed no sentinel, so it never reached its first statement"
        fi
        if [ -n "$_why" ]; then
            n_unrun=$((n_unrun + 1))
            unrun_list="$unrun_list
    presence check for $f (representative: $rep) — $_why"
            continue
        fi
        if str_has "$_present_out" "undefined variable"; then
            absent_here="$absent_here $(printf '%s\n' "$f_names" | tr '\n' ' ')"
        fi
    done
else
    echo "  NOTE: 'make print-SRC_V_release' gave nothing — variant-only detection off"
fi
probe_builtin_present() {
    local first="${1%%/*}"
    case " $absent_here " in *" $first "*) return 1 ;; esac
    return 0
}

if [ "$SHAPES_ONLY" = 0 ]; then
while IFS='|' read -r who prog expect; do
    [ -z "${who:-}" ] && continue
    expect="${expect:-$who: expected}"
    printf '%b\n' "$prog" > "$TMP/p.eigs"
    cap="$(cap_for_name "$who")"
    if ! probe_builtin_present "$who"; then
        n_skipped=$((n_skipped + 1))
        skipped_list="$skipped_list $who"
        if [ -n "$cap" ]; then
            check_absent_call "$NEW" "$(state_for subject "$cap")" "$cap" "${who%%/*}" "$TMP/p.eigs" || rc=1
            if [ -n "$BASE" ] && [ "$(state_for baseline "$cap")" != implemented ]; then
                check_absent_call "$BASE" "$(state_for baseline "$cap")" "$cap" "${who%%/*}" "$TMP/p.eigs" || rc=1
            fi
        fi
        continue
    fi
    n_probe=$((n_probe + 1))
    if [ -n "$BASE" ]; then
        if [ -n "$cap" ] && [ "$(state_for baseline "$cap")" != implemented ]; then
            n_profile_rows=$((n_profile_rows + 1))
            check_absent_call "$BASE" "$(state_for baseline "$cap")" "$cap" "${who%%/*}" "$TMP/p.eigs" || rc=1
        else
            a="$(run_capture "$BASE" 0 "$TMP/p.eigs")"
            b="$(run_capture "$NEW" 0 "$TMP/p.eigs")"
            if [ "$a" = "$b" ]; then n_ident=$((n_ident + 1))
            else
                n_differ=$((n_differ + 1))
                differ_list="$differ_list
    $who
      baseline: $(clip "$a" 90)
      new     : $(clip "$b" 90)"
            fi
        fi
    fi
    s="$(run_capture "$NEW" 1 "$TMP/p.eigs")"
    s_rc="${s%%$'\n'*}"
    u="$(run_capture "$NEW" - "$TMP/p.eigs")"
    if [ "$u" = "$s" ]; then n_unset_eq=$((n_unset_eq + 1))
    else unset_list="$unset_list
    $who
      unset: $(clip "$u" 90)
      =1   : $(clip "$s" 90)"; fi
    why="$(run_did_not_measure "$s_rc")"
    if [ -n "$why" ]; then
        n_unrun=$((n_unrun + 1))
        unrun_list="$unrun_list
    $who — $why: $(clip "$s" 70)"
    elif [ "$s_rc" != "0" ]; then
        if str_has "$s" "$expect"; then n_raise=$((n_raise + 1))
        else
            n_misattr=$((n_misattr + 1))
            misattr_list="$misattr_list
    $who — raised, but not by its own guard: $(clip "$s" 70)"
        fi
    else
        n_silent=$((n_silent + 1))
        silent_list="$silent_list
    $who — still silent under EIGS_STRICT=1: $(clip "$s" 70)"
    fi
done <<<"$PROBES"

while IFS='|' read -r label prog; do
    [ -z "${label:-}" ] && continue
    n_pin=$((n_pin + 1))
    printf '%s\n' "$prog" > "$TMP/pin.eigs"
    s="$(run_capture "$NEW" 1 "$TMP/pin.eigs")"
    why="$(run_did_not_measure "${s%%$'\n'*}")"
    if [ -n "$why" ]; then
        n_unrun=$((n_unrun + 1))
        unrun_list="$unrun_list
    pin: $label — $why"
    elif [ "${s%%$'\n'*}" = "0" ]; then n_pin_ok=$((n_pin_ok + 1))
    else
        n_pin_broke=$((n_pin_broke + 1))
        pin_list="$pin_list
    $label — strict RAISED on a documented answer: $(clip "$s" 70)"
    fi
done <<<"$PINS"

n_valid=0; n_valid_bad=0; valid_list=""; n_valid_expanded=0; n_valid_expanded_bad=0; n_valid_absent=0
if [ -n "$BASE" ]; then
    while IFS= read -r prog; do
        [ -z "$prog" ] && continue
        printf '%b\n' "$prog" > "$TMP/v.eigs"
        who="$(name_for_program "$prog")"; cap="$(cap_for_name "$who")"
        if [ -n "$cap" ] && [ "$(state_for subject "$cap")" != implemented ]; then
            n_valid_absent=$((n_valid_absent + 1))
            check_absent_call "$NEW" "$(state_for subject "$cap")" "$cap" "$who" "$TMP/v.eigs" || rc=1
            if [ "$(state_for baseline "$cap")" != implemented ]; then
                check_absent_call "$BASE" "$(state_for baseline "$cap")" "$cap" "$who" "$TMP/v.eigs" || rc=1
            fi
            continue
        fi
        if [ -n "$cap" ] && [ "$(state_for baseline "$cap")" != implemented ]; then
            n_valid_expanded=$((n_valid_expanded + 1))
            check_absent_call "$BASE" "$(state_for baseline "$cap")" "$cap" "$who" "$TMP/v.eigs" || rc=1
            expanded_reference=""; expanded_good=1
            for mode in - 0 1; do
                b="$(run_capture "$NEW" "$mode" "$TMP/v.eigs")"
                if [ "${b%%$'\n'*}" != 0 ]; then
                    echo "  EXPANDED VALID INPUT FAILED: $who [strict=$mode]: $(clip "$b" 120)"; rc=1; expanded_good=0
                fi
                if [ "$mode" = - ]; then
                    expanded_reference="$b"
                elif [ "$b" != "$expanded_reference" ]; then
                    echo "  EXPANDED VALID OUTPUT DIFFERS: $prog [unset vs strict=$mode]"
                    echo "    unset: $(clip "$expanded_reference" 120)"
                    echo "    =$mode: $(clip "$b" 120)"
                    rc=1; expanded_good=0
                fi
            done
            [ "$expanded_good" = 1 ] || n_valid_expanded_bad=$((n_valid_expanded_bad + 1))
            continue
        fi
        n_valid=$((n_valid + 1))
        for mode in - 0 1; do
            a="$(run_capture "$BASE" "$mode" "$TMP/v.eigs")"
            b="$(run_capture "$NEW" "$mode" "$TMP/v.eigs")"
            if [ "$a" != "$b" ]; then
                n_valid_bad=$((n_valid_bad + 1))
                valid_list="$valid_list
    [strict=${mode}] $prog
      baseline: $(clip "$a" 80)
      new     : $(clip "$b" 80)"
            fi
        done
    done <<<"$VALID"
fi

guarded="$(extract_guard_names src/*.c | sed '/^$/d' | sort -u)"
probed="$(printf '%s\n' "$PROBES" | cut -d'|' -f1 | sed '/^$/d' | sort -u)"
n_guarded=$(printf '%s\n' "$guarded" | sed '/^$/d' | wc -l | tr -d ' ')
missing="$(comm -23 <(printf '%s\n' "$guarded") <(printf '%s\n' "$probed") \
    | grep -vxF -f <(printf '%s\n' $absent_here) || true)"
stale="$(comm -13 <(printf '%s\n' "$guarded") <(printf '%s\n' "$probed"))"

echo "== strict differential =="
echo "  probes=$n_probe pins=$n_pin guarded-names=$n_guarded"
if [ "$n_skipped" -gt 0 ]; then
    echo "  implementation guards omitted (exact absent-call contracts checked for registered extensions): $n_skipped —$skipped_list"
fi
echo "  capability states (ordinary operations, unset/0/1):$NEW_CAPS"
if [ -n "$profile_transitions" ]; then
    echo "  PROFILE TRANSITIONS (not byte-identical):$profile_transitions"
    echo "  expanded guard rows checked only on subject: $n_profile_rows"
fi
if [ -n "$BASE" ]; then echo "  identical-when-off: $n_ident   differing: $n_differ"
else echo "  identical-when-off: SKIPPED (--no-baseline)"; fi
echo "  unset-equals-strict: $n_unset_eq / $n_probe"
echo "  raises-under-strict: $n_raise   silent: $n_silent   misattributed: $n_misattr"
[ "$n_unrun" -gt 0 ] && echo "  probes that did not run: $n_unrun"
echo "  answer-pins held: $n_pin_ok   broken: $n_pin_broke"
if [ -n "$BASE" ]; then
    echo "  valid-input rows unchanged in all three modes: $((n_valid * 3 - n_valid_bad)) / $((n_valid * 3))"
    echo "  expanded valid rows mode-identical (subject rc=0, unset=0=1; baseline absence verified): $((n_valid_expanded - n_valid_expanded_bad)) / $n_valid_expanded"
    echo "  absent valid rows (exact absence verified; NOT valid successes): $n_valid_absent"
fi
[ -n "$unset_list" ] && { echo "  UNSET DIFFERS FROM EIGS_STRICT=1 (the default is not strict):$unset_list"; rc=1; }
[ -n "$differ_list" ] && { echo "  DIFFERING (the EIGS_STRICT=0 path was NOT preserved):$differ_list"; rc=1; }
[ -n "$silent_list" ] && { echo "  SILENT UNDER STRICT:$silent_list"; rc=1; }
[ -n "$misattr_list" ] && { echo "  RAISED BY THE WRONG GUARD (probe does not reach its target):$misattr_list"; rc=1; }
[ -n "$unrun_list" ] && { echo "  DID NOT RUN (the environment, not a guard — nothing is retried):$unrun_list"; rc=1; }
[ -n "$valid_list" ] && { echo "  VALID INPUT CHANGED:$valid_list"; rc=1; }
[ -n "$pin_list" ] && { echo "  PIN BROKEN (strict raised on a documented answer):$pin_list"; rc=1; }
[ -n "$missing" ] && { echo "  GUARDED BUT UNPROBED:"; printf '    %s\n' $missing; rc=1; }
[ -n "$stale" ] && { echo "  PROBED BUT NO LONGER GUARDED (stale probe):"; printf '    %s\n' $stale; rc=1; }
if [ "$n_probe" -lt 55 ] || [ "$n_pin" -lt 14 ] || { [ -n "$BASE" ] && [ "$n_valid" -lt 25 ]; }; then
    echo "  VACUOUS: probes=$n_probe pins=$n_pin valid=$n_valid — below a floor"
    rc=1
fi
if [ "$NO_BASELINE" = 1 ]; then
    echo "  NOTE: identical-when-off was NOT measured (no baseline binary)."
fi

fi # historical wrong-type/valid-input halves

# ------------------------------------------------ typed fixed-shape controls (#1398)
# Candidate discovery is independent of the guards and reviewed contract data.
# Every process/form owns fresh files; no universal malformed numeric prefix.
shape_rows=0; shape_pass=0; shape_absent=0; shape_backend_absent=0; shape_pending=0; shape_fail=0
SHAPE_SUBJECT_SDL=unmeasured; SHAPE_SUBJECT_MIXER=unmeasured
SHAPE_BASELINE_SDL=unmeasured; SHAPE_BASELINE_MIXER=unmeasured
if [ -f "$TMP/shapes/rows" ]; then
    while IFS='|' read -r who max forms legacy exits pending backend; do
        [ -n "$who" ] || continue
        shape_rows=$((shape_rows + 1)); row_good=1
        cap="$(cap_for_name "$who")"
        if ! probe_builtin_present "$who"; then
            printf 'ignore is %s of null\n' "$who" > "$TMP/shape-absent.eigs"
            if [ -n "$cap" ]; then
                if [ "$cap" = gfx ]; then
                    (shape_gfx_limit "$NEW" || exit 125; check_absent_call "$NEW" "$(state_for subject "$cap")" "$cap" "$who" "$TMP/shape-absent.eigs") || row_good=0
                else
                    check_absent_call "$NEW" "$(state_for subject "$cap")" "$cap" "$who" "$TMP/shape-absent.eigs" || row_good=0
                fi
            else
                echo "  SHAPE ABSENCE UNCLASSIFIED: $who"; row_good=0
            fi
            if [ "$row_good" = 1 ]; then
                shape_absent=$((shape_absent + 1)); echo "  UNAVAILABLE shape: $who (not a valid-operation pass)"
            else
                shape_fail=$((shape_fail + 1)); rc=1; break
            fi
            continue
        fi
        if [ "$pending" = 1 ]; then
            shape_pending=$((shape_pending + 1)); rc=1
            echo "  PENDING shape: $who — $(cat "$TMP/shapes/$who/pending")"
            continue
        fi
        shape_base=1
        if [ -n "$BASE" ] && [ -n "$cap" ] && [ "$(state_for baseline "$cap")" != implemented ]; then
            shape_base=0
            printf 'ignore is %s of null\n' "$who" > "$TMP/shape-absent.eigs"
            check_absent_call "$BASE" "$(state_for baseline "$cap")" "$cap" "$who" "$TMP/shape-absent.eigs" || row_good=0
        fi
        shape_subject=subject; shape_baseline=baseline; shape_absence_output=""
        if [ "$backend" != none ]; then
            if ! shape_backend_prepare "$NEW" subject "$backend"; then
                shape_abort "$who" 'backend dependency' 'exact dependency receipt required'; break
            fi
            shape_backend_state=$SHAPE_BACKEND_STATE
            if [ -n "$BASE" ] && [ "$shape_base" = 1 ]; then
                if ! shape_backend_prepare "$BASE" baseline "$backend"; then
                    shape_abort "$who" 'baseline backend dependency' 'exact dependency receipt required'; break
                fi
                if [ "$shape_backend_state" != "$SHAPE_BACKEND_STATE" ]; then
                    shape_abort "$who" 'backend transition' "$shape_backend_state != $SHAPE_BACKEND_STATE"; break
                fi
            fi
            if [ "$shape_backend_state" != present ]; then
                shape_subject=subject-absent; shape_baseline=baseline-absent
                shape_absence_output=$(cat "$TMP/shapes/$who/$shape_backend_state") || {
                    shape_abort "$who" 'backend absence oracle missing' "$shape_backend_state"; break
                }
            fi
        fi
        old_ifs=$IFS; IFS=','; read -r -a shape_forms <<<"$forms"; IFS=$old_ifs
        maximum=""
        for form in "${shape_forms[@]}"; do
            off="$(shape_capture "$NEW" 0 "$TMP/shapes/$who/$shape_subject/0/$form/case.eigs" "$cap")"
            if ! shape_typed_positive_ok "$off" "$exits" "$shape_absence_output"; then shape_abort "$who" "valid $form/0" "$off"; break 2; fi
            on="$(shape_capture "$NEW" 1 "$TMP/shapes/$who/$shape_subject/1/$form/case.eigs" "$cap")"
            if ! shape_typed_positive_ok "$on" "$exits" "$shape_absence_output"; then shape_abort "$who" "valid $form/1" "$on"; break 2; fi
            default="$(shape_capture "$NEW" - "$TMP/shapes/$who/$shape_subject/default/$form/case.eigs" "$cap")"
            if ! shape_typed_positive_ok "$default" "$exits" "$shape_absence_output"; then shape_abort "$who" "valid $form/-" "$default"; break 2; fi
            if [ "$exits" = 1 ]; then
                [ "$off" = $'0\nexit-entered' ] || row_good=0
            else
                shape_done "$off" || row_good=0
            fi
            [ "$off" = "$on" ] && [ "$on" = "$default" ] || row_good=0
            if [ -n "$BASE" ] && [ "$shape_base" = 1 ]; then
                for mode in 0 1 default; do
                    flag=$mode; [ "$mode" = default ] && flag=-
                    old="$(shape_capture "$BASE" "$flag" "$TMP/shapes/$who/$shape_baseline/$mode/$form/case.eigs" "$cap")"
                    if ! shape_typed_positive_ok "$old" "$exits" "$shape_absence_output"; then shape_abort "$who" "baseline $form/$mode" "$old"; break 3; fi
                    [ "$old" = "$off" ] || row_good=0
                done
            fi
            [ "$form" != max ] || maximum=$off
        done
        soft="$(shape_capture "$NEW" 0 "$TMP/shapes/$who/$shape_subject/0/surplus/case.eigs" "$cap")"
        if ! shape_receipt_ok "$soft"; then shape_abort "$who" "strict-off surplus" "$soft"; break; fi
        shape_receipt_ok "$soft" || row_good=0
        if [ "$legacy" = 0 ]; then [ "$soft" = "$maximum" ] || row_good=0
        else shape_done "$soft" || row_good=0; fi
        if [ -n "$BASE" ] && [ "$shape_base" = 1 ]; then
            old="$(shape_capture "$BASE" 0 "$TMP/shapes/$who/$shape_baseline/0/surplus/case.eigs" "$cap")"
            if ! shape_receipt_ok "$old"; then shape_abort "$who" "baseline surplus" "$old"; break; fi
            [ "$old" = "$soft" ] || row_good=0
        fi
        on="$(shape_capture "$NEW" 1 "$TMP/shapes/$who/$shape_subject/1/strict/case.eigs" "$cap")"
        if ! shape_done "$on"; then shape_abort "$who" "strict surplus" "$on"; break; fi
        default="$(shape_capture "$NEW" - "$TMP/shapes/$who/$shape_subject/default/strict/case.eigs" "$cap")"
        if ! shape_done "$default"; then shape_abort "$who" "default surplus" "$default"; break; fi
        shape_done "$on" && [ "$on" = "$default" ] || row_good=0
        if [ -n "$shape_absence_output" ] && [ "$on" != $'0\nshape-complete' ]; then row_good=0; fi
        if [ "$row_good" = 1 ]; then
            if [ -n "$shape_absence_output" ]; then
                shape_backend_absent=$((shape_backend_absent + 1))
                echo "  BACKEND ABSENT shape: $who (documented outcomes + strict surplus; no device-positive claim)"
            else
                shape_pass=$((shape_pass + 1)); echo "  PASS shape: $who (max=$max; forms=$forms)"
            fi
        else
            shape_fail=$((shape_fail + 1)); rc=1
            echo "  FAIL shape: $who (strict/default=$(clip "$on" 160); soft=$(clip "$soft" 160))"
            # Stop at a real unexpected failure; do not run later resource rows.
            break
        fi
    done < "$TMP/shapes/rows"
else
    rc=1; shape_fail=$((shape_fail + 1))
fi
shape_declared=$(python3 -c 'import json; print(len(json.load(open("tests/strict_shape_cases.json"))))')
shape_unrun=$((shape_declared - shape_rows))
echo "== typed fixed-shape controls =="
echo "  declared=$shape_declared examined=$shape_rows passed=$shape_pass failed=$shape_fail unavailable=$shape_absent backend_absent=$shape_backend_absent pending=$shape_pending unrun=$shape_unrun"
[ "$shape_rows" = "$shape_declared" ] && [ "$shape_rows" = "$((shape_pass + shape_absent + shape_backend_absent + shape_fail + shape_pending))" ] && [ "$shape_fail" = 0 ] && [ "$shape_pending" = 0 ] || rc=1
[ -n "$BASE" ] || echo "  NOTE: shape baseline equality was NOT measured."
[ "$shape_fail" = 0 ] || SHAPES_ONLY=1

if [ "$SHAPES_ONLY" = 0 ]; then
# ------------------------------------------------ gfx capability
case "$(state_for subject gfx)" in
    undefined)
        echo "SKIP: not a gfx build"
        gfx_on=0 ;;
    implemented) gfx_on=1 ;;
    *) echo 'FAIL: GFX capability was not measured'; gfx_on=0; rc=1 ;;
esac

if [ "$gfx_on" = 1 ]; then
# name|shape-id|reason. A pair that raises is stale; a pair nothing probes is dead.
ALLOW=$(cat <<'EOF'
gfx_text_height|scalar|the scale slot is documented as `gfx_text_height of 2`, a bare number
gfx_text_width|string|`gfx_text_width of "hello"` is the documented one-argument form
audio_pause|scalar|`audio_pause of 1` is the documented flag form
audio_stop|scalar|`audio_stop of 1` is the documented channel form
audio_music_volume|scalar|`audio_music_volume of 96` is the documented form
gfx_delay|scalar|`gfx_delay of 16` is the documented one-argument form
gfx_title|string|`gfx_title of "name"` is the documented one-argument form
audio_play|list2|a 2-element numeric list IS a sample list -- the valid call
audio_stream_push|list2|a 2-element numeric list IS a sample list -- the valid call
EOF
)
REQUIRED_NAMES="audio_capture_open audio_envelope audio_gain audio_mix audio_music_play
audio_music_volume audio_noise audio_open audio_pause audio_play
audio_play_loop audio_saw audio_sine audio_square audio_stop
audio_stream_open audio_stream_push audio_sweep audio_volume gfx_circle
gfx_clear gfx_clip gfx_delay gfx_fb gfx_line
gfx_open gfx_point gfx_read gfx_rect gfx_rrect
gfx_text gfx_text_height gfx_text_width gfx_title ppu_render_frame"
POP="$(tr '\n' ' ' < src/ext_gfx.c \
  | grep -oE '(ARG_GUARD|ARG_GUARD_TAPED|ARG_GUARD_PRETAKE|STRICT_REQUIRE)\([^;]*;' \
  | grep -oE '"(gfx|audio|ppu)_[a-z_]+", *"[^"]*"' \
  | sed 's/", *"/|/; s/^"//; s/"$//')"
NAMES="$(printf '%s\n' "$POP" | cut -d'|' -f1 | sort -u)"
n_names=$(printf '%s\n' "$NAMES" | sed '/^$/d' | wc -l | tr -d ' ')
name_in_population() {
    case "
$NAMES
" in *"
$1
"*) return 0 ;; esac
    return 1
}
MISSING=""
for req in $REQUIRED_NAMES; do
    name_in_population "$req" || MISSING="$MISSING $req"
done
arity_of() {
    printf '%s\n' "$POP" | awk -F'|' -v n="$1" '
        $1 == n {
            w = $2
            if (match(w, /\[[^]]*\]/)) {
                g = substr(w, RSTART + 1, RLENGTH - 2)
                k = 1
                for (i = 1; i <= length(g); i++) if (substr(g, i, 1) == ",") k++
                if (best == 0 || k < best) best = k
            }
        }
        END { print best + 0 }'
}
shape_text() {
    case "$1" in
        scalar) echo '42' ;;
        string) echo '"zzz"' ;;
        dict)   echo '{"k": 1}' ;;
        list2)  echo '[1, 2]' ;;
        short)  k=$(( $2 - 1 ))
                if [ "$k" -le 0 ]; then echo ''
                elif [ "$k" -eq 1 ]; then echo '([1])'
                else printf '['; i=1; while [ "$i" -le "$k" ]; do
                         [ "$i" -gt 1 ] && printf ', '; printf '%d' "$i"; i=$((i + 1)); done; printf ']\n'
                fi ;;
    esac
}
sweep_verdict() {   # $1 name, $2 argument text
    printf 'ignore is %s of %s\n' "$1" "$2" > "$TMP/p.eigs"
    tries=0
    while [ "$tries" -lt 3 ]; do
        tries=$((tries + 1))
        out="$(EIGS_STRICT=1 "$NEW" "$TMP/p.eigs" 2>&1)"; src=$?
        printf '%s\n' "$out" > "$TMP/last.out"
        if [ "$src" -eq 0 ]; then echo SILENT; return; fi
        case "$out" in
            "Error line 1: $1:"*|*"
Error line 1: $1:"*) echo RAISED-OWN; return ;;
        esac
        case "$out" in
            "Error line "*|*"
Error line "*) echo RAISED-OTHER; return ;;
        esac
        echo "retry: $1 of $2 (exit $src, no runtime error printed)" >> "$TMP/retries"
    done
    echo UNRUN
}

echo "== container-shape sweep =="
ALLOW_NL="
$ALLOW"
PROBED_PAIRS=""
n_rows=0; n_sraised=0; n_ssilent=0; n_sother=0; n_allowed=0; n_sunrun=0
ssilent_list=""; sother_list=""
for name in $NAMES; do
    ar=$(arity_of "$name")
    case "$ar" in
        ''|*[!0-9]*) echo "  FAIL: could not derive an arity for $name (got '$ar')"; rc=1; continue ;;
    esac
    if [ "$ar" -ge 2 ]; then shapes="short scalar string dict"
    else shapes="scalar string dict list2"; fi
    for sh in $shapes; do
        txt="$(shape_text "$sh" "$ar")"
        [ -z "$txt" ] && continue
        n_rows=$((n_rows + 1))
        PROBED_PAIRS="$PROBED_PAIRS
$name|$sh"
        v="$(sweep_verdict "$name" "$txt")"
        allowed=""
        case "$ALLOW_NL" in
            *"
$name|$sh|"*) rest="${ALLOW_NL#*"
$name|$sh|"}"; allowed="${rest%%
*}" ;;
        esac
        case "$v" in
            RAISED-OWN)
                n_sraised=$((n_sraised + 1))
                if [ -n "$allowed" ]; then
                    sother_list="$sother_list
    STALE ALLOWLIST $name|$sh — it raises now; delete the entry"
                    rc=1
                fi ;;
            RAISED-OTHER)
                n_sother=$((n_sother + 1))
                sother_list="$sother_list
    MISATTRIBUTED $name of $txt — raised, but not from $name's own guard"
                rc=1 ;;
            UNRUN)
                n_sunrun=$((n_sunrun + 1))
                sother_list="$sother_list
    DID NOT RUN $name of $txt — nonzero exit, no runtime error, 3 attempts"
                rc=1 ;;
            SILENT)
                if [ -n "$allowed" ]; then n_allowed=$((n_allowed + 1))
                else
                    n_ssilent=$((n_ssilent + 1))
                    ssilent_list="$ssilent_list
    SILENT UNDER STRICT: $name of $txt"
                    rc=1
                fi ;;
        esac
    done
done
echo "  guarded names=$n_names  rows=$n_rows"
echo "  raises-under-strict: $n_sraised   silent: $n_ssilent   misattributed: $n_sother   did-not-run: $n_sunrun"
echo "  quiet on purpose (allowlisted): $n_allowed"
[ -n "$ssilent_list" ] && echo "$ssilent_list"
[ -n "$sother_list" ] && echo "$sother_list"
while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    key="${entry%%|*}"; rest="${entry#*|}"; key="$key|${rest%%|*}"
    case "$PROBED_PAIRS" in
        *"
$key"*) ;;
        *) echo "  DEAD ALLOWLIST $key — no probe ever asks this pair"; rc=1 ;;
    esac
done <<EOF
$ALLOW
EOF
if [ -n "$MISSING" ]; then
    echo "  GUARD REMOVED — pinned builtins no longer carry any guard in src/ext_gfx.c:$MISSING"
    rc=1
fi
if [ "$n_names" -lt 25 ] || [ "$n_rows" -lt 90 ] || [ "$n_sraised" -lt 70 ]; then
    echo "  VACUOUS: names=$n_names rows=$n_rows raised=$n_sraised — below the floor"
    rc=1
fi

# ------------------------------------------------ pixel differential
printf 'print of (gfx_open of [8, 8, "pixdiff-probe"])\n' > "$TMP/open.eigs"
NO_RENDERER=0
if [ "$("$NEW" "$TMP/open.eigs" 2>&1 | tail -1)" != "1" ]; then
    NO_RENDERER=1
    echo "  NOTE: no renderer — pixel identity is OFF; strict-raise and coverage still run."
fi
HEAD='ignore is gfx_open of [32, 32, "pixdiff"]
ignore is gfx_clear of [0, 0, 0]'
TAIL='total is 0
lit is 0
for py in range of 32:
    for px in range of 32:
        c is gfx_read of [px, py]
        if c != null:
            total is total + (c[0] * 7 + c[1] * 13 + c[2] * 17) * (px + py * 32 + 1)
            if c[0] + c[1] + c[2] > 0:
                lit is lit + 1
print of f"digest={total} lit={lit}"'
ROWS=$(cat <<'EOF'
valid-rect|gfx_rect|-|ignore is gfx_rect of [4, 4, 10, 10, 255, 0, 0]
valid-rect-alpha|gfx_rect|-|ignore is gfx_rect of [4, 4, 10, 10, 255, 0, 0, 128]
valid-rrect|gfx_rrect|-|ignore is gfx_rrect of [4, 4, 12, 12, 3, 0, 255, 0]
valid-circle|gfx_circle|-|ignore is gfx_circle of [16, 16, 7, 0, 0, 255]
valid-line|gfx_line|-|ignore is gfx_line of [0, 0, 30, 30, 255, 255, 0]
valid-point|gfx_point|-|ignore is gfx_point of [5, 5, 255, 0, 255]
valid-clear|gfx_clear|-|ignore is gfx_clear of [10, 20, 30]
valid-clip|gfx_clip|-|ignore is gfx_clip of [2, 2, 8, 8]\nignore is gfx_rect of [0, 0, 32, 32, 255, 0, 0]
valid-clip-null|gfx_clip|-|ignore is gfx_clip of null\nignore is gfx_rect of [0, 0, 8, 8, 255, 0, 0]
valid-text|gfx_text|-|ignore is gfx_text of [0, 0, "H", 255, 255, 255]
valid-text-scale|gfx_text|-|ignore is gfx_text of [0, 0, "H", 255, 255, 255, 2]
valid-fb|gfx_fb|-|fb is buffer of 16\nignore is buf_fill of [fb, 0, 16, 0]\nignore is gfx_fb of [fb, 4, 4, 0, 0, 2]
valid-read|gfx_read|-|ignore is gfx_rect of [0, 0, 4, 4, 200, 100, 50]\nprint of (gfx_read of [1, 1])
valid-open-title|gfx_open|-|ignore is gfx_title of "pixdiff2"\nignore is gfx_rect of [1, 1, 3, 3, 9, 9, 9]
wrong-rect-slot0|gfx_rect|0|ignore is gfx_rect of ["4", 4, 10, 10, 255, 0, 0]
wrong-rect-slot7|gfx_rect|7|ignore is gfx_rect of [4, 4, 10, 10, 255, 0, 0, "128"]
wrong-rrect-slot0|gfx_rrect|0|ignore is gfx_rrect of ["4", 4, 12, 12, 3, 0, 255, 0]
wrong-rrect-slot8|gfx_rrect|8|ignore is gfx_rrect of [4, 4, 12, 12, 3, 0, 255, 0, "128"]
wrong-circle-slot0|gfx_circle|0|ignore is gfx_circle of ["16", 16, 7, 0, 0, 255]
wrong-circle-slot6|gfx_circle|6|ignore is gfx_circle of [16, 16, 7, 0, 0, 255, "128"]
wrong-line-slot0|gfx_line|0|ignore is gfx_line of ["0", 0, 30, 30, 255, 255, 0]
wrong-line-slot6|gfx_line|6|ignore is gfx_line of [0, 0, 30, 30, 255, 255, "0"]
wrong-point-slot0|gfx_point|0|ignore is gfx_point of ["5", 5, 255, 0, 255]
wrong-point-slot4|gfx_point|4|ignore is gfx_point of [5, 5, 255, 0, "255"]
wrong-clear-slot0|gfx_clear|0|ignore is gfx_clear of ["10", 20, 30]
wrong-clear-slot2|gfx_clear|2|ignore is gfx_clear of [10, 20, "30"]
wrong-clip-slot0|gfx_clip|0|ignore is gfx_clip of ["2", 2, 8, 8]\nignore is gfx_rect of [0, 0, 32, 32, 255, 0, 0]
wrong-clip-slot3|gfx_clip|3|ignore is gfx_clip of [2, 2, 8, "8"]\nignore is gfx_rect of [0, 0, 32, 32, 255, 0, 0]
wrong-text-slot0|gfx_text|0|ignore is gfx_text of ["0", 0, "H", 255, 255, 255]
wrong-text-slot1|gfx_text|1|ignore is gfx_text of [0, "0", "H", 255, 255, 255]
wrong-text-slot3|gfx_text|3|ignore is gfx_text of [0, 0, "H", "255", 255, 255]
wrong-text-slot6|gfx_text|6|ignore is gfx_text of [0, 0, "H", 255, 255, 255, "2"]
wrong-read-slot0|gfx_read|0|ignore is gfx_rect of [0, 0, 4, 4, 200, 100, 50]\nprint of (gfx_read of ["1", 1])
wrong-read-slot1|gfx_read|1|ignore is gfx_rect of [0, 0, 4, 4, 200, 100, 50]\nprint of (gfx_read of [1, "1"])
wrong-fb-slot1|gfx_fb|1|fb is buffer of 16\nignore is buf_fill of [fb, 0, 16, 0]\nignore is gfx_fb of [fb, "4", 4, 0, 0, 2]
wrong-fb-slot5|gfx_fb|5|fb is buffer of 16\nignore is buf_fill of [fb, 0, 16, 0]\nignore is gfx_fb of [fb, 4, 4, 0, 0, "2"]
wrong-open-slot0|gfx_open|0|ignore is gfx_open of ["16", 16, "reopen"]\nignore is gfx_rect of [0, 0, 8, 8, 255, 0, 0]
EOF
)
mkprog() { printf '%s\n' "$HEAD" > "$1"; printf '%b\n' "$2" >> "$1"; printf '%s\n' "$TAIL" >> "$1"; }
n_prow=0; n_pvalid=0; n_pwrong=0; n_pident=0; n_pdiffer=0
n_praise=0; n_psilent=0; n_pmis=0
pdiffer=""; psilent=""; pmis=""; pvac=""
covered_names=""; covered_slots=""
blank_digest=""
if [ "$NO_RENDERER" = 0 ]; then
    mkprog "$TMP/blank.eigs" "ignore is gfx_delay of 0"
    blank="$(run_capture "$NEW" 0 "$TMP/blank.eigs")"
    blank_digest="${blank#*$'\n'}"
fi
PIXBASE="$BASE"
[ "$NO_RENDERER" = 1 ] && PIXBASE=""
[ -n "$BASE" ] && [ "$(state_for baseline gfx)" != implemented ] && PIXBASE=""
while IFS='|' read -r label who slot prog; do
    [ -z "${label:-}" ] && continue
    n_prow=$((n_prow + 1))
    covered_names="$covered_names $who"
    [ "$slot" != "-" ] && covered_slots="$covered_slots $who:$slot"
    mkprog "$TMP/p.eigs" "$prog"
    b="$(run_capture "$NEW" 0 "$TMP/p.eigs")"
    s="$(run_capture "$NEW" 1 "$TMP/p.eigs")"
    u="$(run_capture "$NEW" - "$TMP/p.eigs")"
    [ "$u" = "$s" ] || { pdiffer="$pdiffer
    $label [unset vs EIGS_STRICT=1, same binary] — the default is not strict"; rc=1; }
    if [ "$slot" = "-" ]; then
        n_pvalid=$((n_pvalid + 1))
        if [ "$NO_RENDERER" = 0 ] && [ "$who" != "gfx_read" ] && [ "${b#*$'\n'}" = "$blank_digest" ]; then
            pvac="$pvac
    $label — draws nothing: identical to the blank canvas"
        fi
        if [ "$s" != "$b" ]; then
            pdiffer="$pdiffer
    $label [strict vs plain, same binary] — a guard rejects a LEGITIMATE call
      plain : $(clip "$b" 80)
      strict: $(clip "$s" 80)"
            rc=1
        fi
    else
        n_pwrong=$((n_pwrong + 1))
        if [ "${s%%$'\n'*}" = "0" ]; then
            n_psilent=$((n_psilent + 1))
            psilent="$psilent
    $label — still silent under EIGS_STRICT=1: $(clip "$s" 70)"
        elif str_has "$s" "$who: expected"; then n_praise=$((n_praise + 1))
        else
            n_pmis=$((n_pmis + 1))
            pmis="$pmis
    $label — raised, but not by $who's own guard: $(clip "$s" 70)"
        fi
    fi
    [ -z "$PIXBASE" ] && continue
    a="$(run_capture "$PIXBASE" 0 "$TMP/p.eigs")"
    if [ "$a" = "$b" ]; then n_pident=$((n_pident + 1))
    else
        n_pdiffer=$((n_pdiffer + 1))
        pdiffer="$pdiffer
    $label — the default path was NOT preserved
      baseline: $(clip "$a" 80)
      new     : $(clip "$b" 80)"
        rc=1
    fi
done <<<"$ROWS"

guarded_renderer="$(awk '
    /^Value\* builtin_/ { name = $0; sub(/.*builtin_/, "", name); sub(/\(.*/, "", name); has = 0; g = 0 }
    /g_renderer/        { if (name != "") has = 1 }
    /(ARG_GUARD|STRICT_REQUIRE)\(/ { if (name != "") g = 1 }
    /^}/                { if (name != "" && has && g) print name; name = "" }
' src/ext_gfx.c | sort -u)"
missing_names=""
for nm in $guarded_renderer; do
    case " $covered_names " in *" $nm "*) ;; *) missing_names="$missing_names $nm" ;; esac
done
missing_slots=""
awk '
    /^Value\* builtin_/ { name = $0; sub(/.*builtin_/, "", name); sub(/\(.*/, "", name) }
    match($0, /gfx_nums\(arg, [0-9]+, [0-9]+\)/) {
        s = substr($0, RSTART, RLENGTH); gsub(/[^0-9 ]/, " ", s)
        n = split(s, f, " "); lo = ""; hi = ""
        for (i = 1; i <= n; i++) if (f[i] != "") { if (lo == "") lo = f[i]; else hi = f[i] }
        if (name != "" && lo != "" && hi != "") print name, lo, hi
    }
' src/ext_gfx.c | sort -u > "$TMP/slots"
while read -r nm a b; do
    [ -z "${nm:-}" ] && continue
    last=$((b - 1))
    for want in "$a" "$last"; do
        case " $covered_slots " in *" $nm:$want "*) ;; *) missing_slots="$missing_slots $nm:$want" ;; esac
    done
done < "$TMP/slots"

echo "== gfx pixel differential =="
echo "  rows=$n_prow (valid=$n_pvalid wrong=$n_pwrong)"
if [ -n "$PIXBASE" ]; then
    echo "  identical-when-off: $n_pident   differing: $n_pdiffer"
elif [ "$NO_RENDERER" = 1 ]; then
    echo "  identical-when-off: SKIPPED (no renderer)"
elif [ -n "$BASE" ]; then
    echo "  identical-when-off: NOT COMPARABLE (baseline GFX absent; subject strict/valid/pixel coverage still checked)"
else
    echo "  identical-when-off: SKIPPED (--no-baseline)"
fi
echo "  raises-under-strict: $n_praise   silent: $n_psilent   misattributed: $n_pmis"
[ "$NO_RENDERER" = 0 ] && echo "  blank canvas: $blank_digest"
[ -n "$pdiffer" ] && { echo "  DIFFERING:$pdiffer"; rc=1; }
[ -n "$psilent" ] && { echo "  SILENT UNDER STRICT:$psilent"; rc=1; }
[ -n "$pmis" ] && { echo "  RAISED BY THE WRONG GUARD:$pmis"; rc=1; }
[ -n "$pvac" ] && { echo "  VACUOUS ROW:$pvac"; rc=1; }
if [ -n "$missing_names" ]; then
    echo "  GUARDED, TOUCHES THE RENDERER, NO PIXEL ROW:"
    printf '    %s\n' $missing_names
    rc=1
fi
if [ -n "$missing_slots" ]; then
    echo "  GUARDED SLOT WITH NO WRONG-TYPED ROW (first/last of a gfx_nums range):"
    printf '    %s\n' $missing_slots
    rc=1
fi
if [ "$n_prow" -lt 1 ]; then echo "  VACUOUS: pixel rows=0"; rc=1; fi
fi

fi # historical graphics halves

if [ -n "$FP_NEW_START" ]; then
    _fp_now="$(bin_fingerprint "$NEW")"
    if [ "$_fp_now" != "$FP_NEW_START" ]; then
        echo "  BINARY CHANGED UNDER THIS RUN: $NEW"
        echo "                 at start: $FP_NEW_START"
        echo "                 at end:   $_fp_now"
        rc=1
    fi
fi
if [ -n "$FP_BASE_START" ]; then
    _fp_now="$(bin_fingerprint "$BASE")"
    if [ "$_fp_now" != "$FP_BASE_START" ]; then
        echo "  BASELINE BINARY CHANGED UNDER THIS RUN: $BASE"
        rc=1
    fi
fi
verdict_printed=1
if [ "$rc" = 0 ]; then echo "OK"; exit 0; fi
echo "FAIL"
exit 1
