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
#   identical-when-off      baseline vs subject, flag unset, stdout+stderr+rc;
#                           valid-input rows in both modes when a baseline is given
#   gfx container-shape sweep   ext_gfx.c want-strings, wrong containers
#   gfx pixel differential  canvas digests and source coverage. Every pixel
#                           row is compared with the flag off; a flag-off
#                           canvas change is a difference, with no waiver.
#   binary-held-still       cksum+size+mtime of the subject (and baseline)
# A build without gfx builtins prints one line, "SKIP: not a gfx build",
# and does not treat the gfx halves as a pass.
#
#   bash tools/strict_differential.sh <baseline-binary>
#   bash tools/strict_differential.sh --no-baseline
set -uo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"

NEW="${EIGS_DIFF_NEW:-./src/eigenscript}"
BASE="${1:-}"
NO_BASELINE=0
if [ "$BASE" = "--no-baseline" ]; then NO_BASELINE=1; BASE=""; fi
export SDL_VIDEODRIVER="${SDL_VIDEODRIVER:-dummy}"
export SDL_AUDIODRIVER="${SDL_AUDIODRIVER:-dummy}"

# Matchers are bash case-globs: no pipe, so pipefail cannot invert a match.
# Bodies are pinned byte-for-byte (tools/pipefail_verdict_check.sh).
str_has()      { case "$1" in *"$2"*) return 0 ;; esac; return 1 ; }
str_has_line() { case $'\n'"$1"$'\n' in *$'\n'"$2"$'\n'*) return 0 ;; esac; return 1 ; }
str_has_word() { case " $1 " in *" $2 "*) return 0 ;; esac; return 1 ; }

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

TMP="$(mktemp -d)"
verdict_printed=0
_sd_main_depth=$BASH_SUBSHELL
_sd_exit() {
    local es=$?
    [ "$BASH_SUBSHELL" = "${_sd_main_depth:-}" ] || return 0
    rm -rf "${TMP:-}"
    if [ "${verdict_printed:-0}" != "1" ]; then
        if [ "$es" = "0" ]; then
            echo "  ABORTED: this differential was terminated before printing a verdict."
        else
            echo "  ABORTED: this differential exited (rc=$es) before printing a verdict."
        fi
    fi
}
trap _sd_exit EXIT

# name|program[|expect]  — wrong-typed call; expect defaults to "<name>: expected"
PROBES=$(cat <<'EOF'
abs|print of (abs of "x")
acos|print of (acos of "x")
asin|print of (asin of "x")
atan|print of (atan of "x")
atan2|print of (atan2 of ["y", 1])
buf_len|print of (buf_len of "x")
ceil|print of (ceil of "x")
chdir|print of (chdir of 42)
char_at|print of (char_at of [42, 0])
contains|print of (contains of [[1, 2, 3], 2])
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
ord|print of (ord of 42)
proc_write|print of (proc_write of [42, 99])
exec_capture|print of (exec_capture of 42)
proc_wait|print of (proc_wait of "x")
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
text_builder_part_count|print of (text_builder_part_count of 42)
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
tensor_load|write_bytes of ["@TMP@/nan.tensor", [1, 0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 248, 127, 0, 0, 0, 0, 0, 0, 4, 64]]\nprint of (tensor_load of "@TMP@/nan.tensor")|tensor_load: result is not a number
divide|print of (divide of [[1], [0]])|divide: division by zero
split|print of (split of 42)
scan_ints|print of (scan_ints of ({"k": 1}))
scan_tokens|print of (scan_tokens of ({"k": 1}))
scan_int_tokens|print of (scan_int_tokens of ({"k": 1}))
tokenize_ids|print of (tokenize_ids of 42)
tokenize_with_names|print of (tokenize_with_names of 42)
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
EOF
)

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
print of (len of (scan_tokens of "a b"))
print of (len of (scan_int_tokens of "1 x"))
print of (len of (tokenize_ids of "x is 1"))
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
EOF
)

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
    if [ "$strict" = "-" ]; then out="$("$bin" "$f" 2>&1)"; rc=$?
    else out="$(EIGS_STRICT="$strict" "$bin" "$f" 2>&1)"; rc=$?; fi
    printf '%s\n%s' "$rc" "$out"
}
clip() { printf '%s' "$1" | tr '\n' ' ' | cut -c1-"${2:-80}"; }

extract_guard_names() {
    awk '
    /(ARG_GUARD(_TAPED|_PRETAKE)?|STRICT_REQUIRE|STRICT_DOMAIN|num_guard_named)\(/ { acc = ""; collecting = 1 }
    collecting { acc = acc $0; if (acc ~ /\);[ \t]*$/ || $0 ~ /\);/) {
        collecting = 0
        n = split(acc, parts, "\"")
        if (n >= 2) print parts[2]
    } }
    ' "$@"
}

rc=0
n_probe=0; n_ident=0; n_differ=0; n_raise=0; n_silent=0
n_pin=0; n_pin_ok=0; n_pin_broke=0; n_misattr=0; n_unrun=0; n_skipped=0
differ_list=""; silent_list=""; pin_list=""; misattr_list=""; unrun_list=""; skipped_list=""

release_srcs="$(make print-SRC_V_release 2>/dev/null | tr ' ' '\n' | sed '/^$/d' | sort -u)"
absent_here=""
if [ -n "$release_srcs" ]; then
    for f in src/*.c; do
        str_has_line "$release_srcs" "$f" && continue
        f_names="$(extract_guard_names "$f" | sed 's,/.*,,' | sed '/^$/d' | sort -u)"
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

while IFS='|' read -r who prog expect; do
    [ -z "${who:-}" ] && continue
    expect="${expect:-$who: expected}"
    if ! probe_builtin_present "$who"; then
        n_skipped=$((n_skipped + 1))
        skipped_list="$skipped_list $who"
        continue
    fi
    n_probe=$((n_probe + 1))
    printf '%b\n' "$prog" > "$TMP/p.eigs"
    if [ -n "$BASE" ]; then
        a="$(run_capture "$BASE" - "$TMP/p.eigs")"
        b="$(run_capture "$NEW" - "$TMP/p.eigs")"
        if [ "$a" = "$b" ]; then n_ident=$((n_ident + 1))
        else
            n_differ=$((n_differ + 1))
            differ_list="$differ_list
    $who
      baseline: $(clip "$a" 90)
      new     : $(clip "$b" 90)"
        fi
    fi
    s="$(run_capture "$NEW" 1 "$TMP/p.eigs")"
    s_rc="${s%%$'\n'*}"
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

n_valid=0; n_valid_bad=0; valid_list=""
if [ -n "$BASE" ]; then
    while IFS= read -r prog; do
        [ -z "$prog" ] && continue
        n_valid=$((n_valid + 1))
        printf '%b\n' "$prog" > "$TMP/v.eigs"
        for mode in - 1; do
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
    echo "  probes skipped (builtin not in this build): $n_skipped —$skipped_list"
fi
if [ -n "$BASE" ]; then echo "  identical-when-off: $n_ident   differing: $n_differ"
else echo "  identical-when-off: SKIPPED (--no-baseline)"; fi
echo "  raises-under-strict: $n_raise   silent: $n_silent   misattributed: $n_misattr"
[ "$n_unrun" -gt 0 ] && echo "  probes that did not run: $n_unrun"
echo "  answer-pins held: $n_pin_ok   broken: $n_pin_broke"
if [ -n "$BASE" ]; then
    echo "  valid-input rows unchanged in BOTH modes: $((n_valid * 2 - n_valid_bad)) / $((n_valid * 2))"
fi
[ -n "$differ_list" ] && { echo "  DIFFERING (the default path was NOT preserved):$differ_list"; rc=1; }
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

# ------------------------------------------------ gfx capability
printf 'print of (gfx_text_width of ["m", 1])\n' > "$TMP/gfxprobe.eigs"
gfx_probe_out="$("$NEW" "$TMP/gfxprobe.eigs" 2>&1 || true)"
case "$gfx_probe_out" in
    *"undefined variable"*)
        echo "SKIP: not a gfx build"
        gfx_on=0 ;;
    *) gfx_on=1 ;;
esac

if [ "$gfx_on" = 1 ]; then
# name|shape-id|reason. A pair that raises is stale; a pair nothing probes is dead.
ALLOW=$(cat <<'EOF'
gfx_text_height|scalar|the scale slot is documented as `gfx_text_height of 2`, a bare number
gfx_text_height|list2|[scale] with a numeric first slot is the documented list form; the surplus slot is #989
gfx_text_width|string|`gfx_text_width of "hello"` is the documented one-argument form
audio_pause|scalar|`audio_pause of 1` is the documented flag form
audio_stop|scalar|`audio_stop of 1` is the documented channel form
audio_music_volume|scalar|`audio_music_volume of 96` is the documented form
audio_music_volume|list2|[volume] with a numeric first slot is the documented list form; the surplus slot is #989
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
    blank="$(run_capture "$NEW" - "$TMP/blank.eigs")"
    blank_digest="${blank#*$'\n'}"
fi
PIXBASE="$BASE"
[ "$NO_RENDERER" = 1 ] && PIXBASE=""
while IFS='|' read -r label who slot prog; do
    [ -z "${label:-}" ] && continue
    n_prow=$((n_prow + 1))
    covered_names="$covered_names $who"
    [ "$slot" != "-" ] && covered_slots="$covered_slots $who:$slot"
    mkprog "$TMP/p.eigs" "$prog"
    b="$(run_capture "$NEW" - "$TMP/p.eigs")"
    if [ "$slot" = "-" ]; then
        n_pvalid=$((n_pvalid + 1))
        if [ "$NO_RENDERER" = 0 ] && [ "$who" != "gfx_read" ] && [ "${b#*$'\n'}" = "$blank_digest" ]; then
            pvac="$pvac
    $label — draws nothing: identical to the blank canvas"
        fi
        s="$(run_capture "$NEW" 1 "$TMP/p.eigs")"
        if [ "$s" != "$b" ]; then
            pdiffer="$pdiffer
    $label [strict vs plain, same binary] — a guard rejects a LEGITIMATE call
      plain : $(clip "$b" 80)
      strict: $(clip "$s" 80)"
            rc=1
        fi
    else
        n_pwrong=$((n_pwrong + 1))
        s="$(run_capture "$NEW" 1 "$TMP/p.eigs")"
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
    a="$(run_capture "$PIXBASE" - "$TMP/p.eigs")"
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
