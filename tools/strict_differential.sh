#!/usr/bin/env bash
# #971 Phase B: the differential that backs the safety claim.
#
# The claim this change makes is narrow and total: converting a fail-soft
# guard to ARG_GUARD changes NOTHING when EIGS_STRICT is unset, and makes
# the same mistake LOUD when it is set. Both halves need an oracle, and
# the first half's oracle is the previous binary.
#
#   identical-when-off   baseline vs new, EIGS_STRICT unset, byte-for-byte
#                        over stdout+stderr+exit code
#   raises-under-strict  new binary, EIGS_STRICT=1, must exit nonzero and
#                        name the builtin
#   pins                 fs:ANSWER sites must NOT raise under strict — the
#                        half that stops the reform overshooting into the
#                        documented answers
#
# The probe table below is hand-written (a call needs the right arity, and
# `--api` does not carry arity), which makes it exactly the sibling list
# §1 of mechanical-gates warns about. So it is CROSS-CHECKED: the set of
# builtin names appearing in an ARG_GUARD is derived from the source, and
# any guarded builtin with no probe FAILS this script. Adding a guard
# without a probe goes red rather than passing quietly.
#
# Usage: bash tools/strict_differential.sh <baseline-binary>
#   <baseline-binary> is a build of the PARENT commit. Build one with:
#     git worktree add --detach /tmp/base <sha> && make -C /tmp/base
#   Without it, the identical-when-off half is skipped and the script says
#   so and exits 1 — a differential with no reference is not a pass.
#   --no-baseline accepts that deliberately (what CI runs).
#
# WHAT THIS DOES NOT COVER, stated so the next reader does not assume it:
#   - UNPROBEABLE is an escape hatch. A name added there leaves the
#     "guarded but unprobed" set with no proof of unreachability; the only
#     thing bounding it is the staleness check, which fires if the guard it
#     excuses disappears entirely. Adding a name is a review event.
#   - The probe table is hand-written. The cross-check makes an UNPROBED
#     guard fail, but it cannot make a BADLY CHOSEN probe fail beyond the
#     attribution check — and that check only proves the raise came from
#     the named guard, not that the probe exercises the interesting branch.
#   - --sweep is discovery, not a gate: it has no allowlist, so nothing
#     fails when a new laundering builtin appears. Making it a gate needs a
#     pinned expected-quiet list, which nobody has written.
# UNDER LOAD. Every measurement here is one short child process, and the tool
# makes no timing assumption: nothing is backgrounded, nothing polls, no probe
# depends on scheduling order, and a probe that hangs hangs (it is not raced
# against a timer, so a slow box cannot turn a pass into a fail). What a loaded
# box CAN do is stop a child from running at all — a fork that fails, a kill, a
# binary relinked underneath the run — and until 2026-09-07 that arrived as a
# finding ABOUT THE CODE: a probe killed by a signal exits nonzero, so it was
# scored "raised, but not by its own guard", and a harness that died mid-run
# printed no verdict at all while still exiting nonzero. Both now say what they
# are: `probes that did not run` is its own bucket, naming the exit status, and
# the EXIT trap prints ABORTED when the script exits before its verdict line.
# A red from either is still a red — nothing is retried, and a crash (signal)
# is reported as a crash — but it names the environment instead of the table.
#
#   - The probe row's THIRD field (#971 Phase C/D + NaN) is the substring
#     the strict raise must carry; it defaults to "<who>: expected", the
#     shape ARG_GUARD/STRICT_REQUIRE emit. A NaN source (num_guard_named)
#     raises "<who>: result is not a number"; a STRICT_DOMAIN site raises
#     "<who>: <what>"; json_path raises "json_path: invalid JSON". The
#     cross-check derives its name set from ALL of those spellings, so a
#     guard of any kind without a probe row still goes red — but a row
#     whose expect field is too loose (a bare builtin name) is the same
#     vacuity the "<name>: expected" rule closed, and nothing here
#     catches it beyond review.

set -uo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"

# EIGS_DIFF_NEW lets the harness be pointed at another build, which is how
# it is validated: run it with NEW := the previous release's binary and the
# loudness detector must fire, because that binary lacks the guards this
# tree added. Measured 2026-09-07 against the v0.43.0 build:
# `raises-under-strict: 77 silent: 21` and FAIL, where this tree scores
# 98/0 and OK. (The stale-waiver check is not exercised that way while both
# waiver lists are empty, which they are — see the waiver block below. It is
# exercised by ADDING a waiver for a probe that does not diverge, which is
# what it exists to catch.) A harness that has never failed has not been
# shown to work.
NEW="${EIGS_DIFF_NEW:-./src/eigenscript}"
BASE="${1:-}"

# --no-baseline runs every half EXCEPT identical-when-off, and passes on those.
# It exists so CI has something: without it this tool only ever runs on a dev
# box that happens to have built the parent commit, and a harness nobody runs
# rots. The half it drops is the one that needs two binaries; the halves it
# keeps (does every guard still raise, does it raise from its OWN guard, do the
# documented answers stay quiet, is every guard probed) catch a removed guard,
# a broken pin and an unprobed guard on their own.
NO_BASELINE=0
if [ "$BASE" = "--no-baseline" ]; then NO_BASELINE=1; BASE=""; fi
# --selftest measures THIS SCRIPT, not the build: it needs no binary and runs
# in a tenth of a second. See the selftest block below for what it pins.
SELFTEST=0
if [ "$BASE" = "--selftest" ]; then SELFTEST=1; BASE=""; fi

[ "$SELFTEST" = "1" ] || [ -x "$NEW" ] || { echo "FAIL: no built binary at $NEW"; exit 1; }

# ------------------------------------------------ did the binary hold still?
# $NEW is a PATH, opened afresh for each of ~130 probes, and in this tree
# src/eigenscript is a hard link to build/<variant>/eigenscript (#740): a
# `make` anywhere in the same worktree re-points it mid-run. Two probes in one
# run then measure two different binaries, and the report reads as a finding
# about a guard — "silent" if the new binary lacks it, "raised by the wrong
# guard" if it words the message differently. run_all_tests.sh has carried the
# #681 fingerprint guard for exactly this since 2026, but it re-checks at
# SECTION SEAMS, which is after this tool has already printed its verdict; and
# this tool is also run standalone, where nothing checks at all. So it now
# checks its own subject, with the same fingerprint shape #681 uses. Cost: two
# cksums of a ~1 MB file per run.
# (This is NOT the cause of #1120 — a swapped binary cannot produce a capture
# that CONTAINS the message the matcher says is absent — but it is a
# neighbouring way to get a confusing red out of a green tree, and it is
# cheaper to rule out by construction than to argue about after the fact.)
bin_fingerprint() {   # <path> -> "cksum size mtime", or "" if unreadable
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
FP_NEW_START=""; FP_BASE_START=""
if [ "$SELFTEST" != "1" ]; then
    FP_NEW_START="$(bin_fingerprint "$NEW")"
    [ -n "$BASE" ] && FP_BASE_START="$(bin_fingerprint "$BASE")"
fi

# ------------------------------------------------- how this script matches (#1120)
# EVERY verdict below is a string match, and until #1120 several of them were
# spelled `printf ... | grep -q ...`. Under `set -o pipefail` that is a RACE,
# not a test: `grep -q` exits the instant it matches and closes the read end,
# the writer then takes SIGPIPE and exits 141, and pipefail reports the
# PIPELINE as 141 — a failed match — while grep's own status was 0, MATCHED.
# The verdict then contradicts the evidence printed beside it, which is exactly
# what #1120 reported: a probe scored "raised by the wrong guard" whose own
# diagnostic contained the guard's message.
#
# Measured on this tree, 4-core box at load 12-16:
#   isolated  `printf | grep -qF` on a 157-byte capture: 21 false no-matches in
#             20,000 evaluations, every one rc=141 (SIGPIPE).
#   this tool with the pipe form restored at the probe matcher: 18 red runs in
#             186, all misattributions, spread over 18 DIFFERENT probes — a
#             uniform spray across the table is the signature of a harness
#             race, not of a guard.
#   this tool as it stands: 0 red in 300.
# The race becomes CERTAIN once the capture exceeds the pipe buffer: the writer
# must block, so it is always still writing when the reader exits. `--selftest`
# pins that shape, so the regression cannot come back quietly.
#
# So no pipeline decides anything here. These three do the whole job with
# bash's own matcher: no fork, no pipe, no status to misread. They are also
# what --selftest exercises, so the selftest and the probes share one matcher.
# str_has      <haystack> <needle>     substring, what `grep -qF` meant
# str_has_line <haystack> <whole line>  what `grep -qxF` meant
# str_has_word <space list> <name>      what `grep -qw` meant on these lists
# The needles are QUOTED inside the patterns, so a glob character in one is a
# literal — the same promise -F made.
str_has()      { case "$1" in *"$2"*) return 0 ;; esac; return 1 ; }
str_has_line() { case $'\n'"$1"$'\n' in *$'\n'"$2"$'\n'*) return 0 ;; esac; return 1 ; }
str_has_word() { case " $1 " in *" $2 "*) return 0 ;; esac; return 1 ; }

# The probe table is also read without a pipeline: `grep -F "$w|" | head -1`
# put the same SIGPIPE on grep. Nothing consulted its status, so it was never a
# false verdict — but leaving the construct in a file whose header now bans it
# is how it comes back.
probe_prog_for() {   # <probe name> -> that row's program field, or ""
    local want="$1" _who _prog _rest
    while IFS='|' read -r _who _prog _rest; do
        if [ "$_who" = "$want" ]; then printf '%s' "$_prog"; return 0; fi
    done <<<"$PROBES"
    return 1
}

TMP="$(mktemp -d)"
# ONE trap (a second EXIT trap would silently replace this one). It cleans up
# and then answers the question a bare nonzero exit cannot: did this script
# reach its verdict? A run killed mid-way, or aborted by `set -u` on an unbound
# name, exits nonzero having printed no finding — which reads downstream as
# "the gate found something" and sends the next person hunting a guard that is
# fine. Seen once in a full-suite run (2026-09-06): [99s] printed FAIL and its
# diagnostic re-run printed a completely clean report, because the failing run
# was discarded rather than shown. If that happens again this line says so.
verdict_printed=0
_sd_main_pid=$BASHPID
_sd_exit() {
    local es=$?
    # ONLY the top-level shell. bash runs an EXIT trap in a subshell that is
    # killed by a signal too, and this trap both deletes $TMP and speaks: a
    # signalled command substitution would otherwise remove the temp dir out
    # from under the still-running parent and print ABORTED before the parent
    # reaches its verdict. $BASHPID is per-subshell where $$ is not.
    [ "$BASHPID" = "${_sd_main_pid:-}" ] || return 0
    rm -rf "${TMP:-}"
    if [ "${verdict_printed:-0}" != "1" ]; then
        if [ "$es" = "0" ]; then
            echo "  ABORTED: this differential was terminated before printing a verdict."
        else
            echo "  ABORTED: this differential exited (rc=$es) before printing a verdict."
        fi
        echo "           Nothing above is a finding about the code under test —"
        echo "           the harness itself did not finish (killed, or an unbound"
        echo "           name under 'set -u'). Re-run it; if it aborts again, the"
        echo "           abort is the bug."
    fi
}
trap _sd_exit EXIT

# ---------------------------------------------------------------- probes
# name|program[|expect]
# Each program calls the builtin with a WRONG-TYPED argument at the right
# arity, so the guard under test is the one that fires. `who` is the name
# ARG_GUARD reports, which is what the cross-check below matches on. The
# optional third field is the message substring the raise must carry when
# it is not ARG_GUARD's "<who>: expected" (the NaN and domain rows).
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
store_delete|print of (store_delete of [42, "col", "k"])
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
store_count|print of (store_count of [42, "col"])
store_drop|print of (store_drop of [42, "col"])
store_update|print of (store_update of [42, "col", "k", {"a": 1}])
store_update|print of (store_update of [(store_open of "@TMP@/probe.db"), "col", ([1, 2]), {"a": 1}])
stream_open|print of (stream_open of [42, 1])
write_text|print of (write_text of [42, "x"])
add/subtract/multiply/divide/pow|print of (add of ["x", 1])
gfx_open|print of (gfx_open of ["800", "600", "t"])
audio_open|print of (audio_open of ["44100", "1"])
audio_capture_open|print of (audio_capture_open of ["44100", "1"])
audio_stream_open|print of (audio_stream_open of ["44100", "1"])
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
EOF
)
# A probe that needs a real resource must build it under this run's own $TMP,
# which the EXIT trap removes. The heredoc above is quoted (so a program can
# contain a literal $ safely), hence the placeholder rather than direct
# expansion. Bought by the store_update key probe: pointed at a fixed
# /tmp path it left a database behind, and a leftover unreadable file there
# wedged the gate for every later run — `store_open` refused it, the probe
# raised from the wrong place, and the tool reported `misattributed: 1`
# forever with nothing to do with the code under test.
PROBES="${PROBES//@TMP@/$TMP}"

# fs:ANSWER pins — a 0/"" that is the documented RESULT. Strict must leave
# these alone. Without this half the reform has no failure mode: converting
# everything would score a perfect "raises-under-strict".
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

# VALID-input rows. Every probe above hands a builtin a WRONG argument, so the
# whole harness was structurally blind to a regression on CORRECT input: a
# guard whose condition is too broad, a split that reordered a real branch, an
# off-by-one in a hoisted check would all pass every row above. These run the
# same program on BOTH binaries in BOTH modes and require byte-identical
# output — including under strict, which is where an over-broad guard shows up
# as a raise on a legitimate call. Found missing by a blind review.
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
EOF
)

# ---------------------------------------------------- divergence waivers
# A waiver here says: "this probe's DEFAULT-path answer legitimately changes,
# and here is why." It is compared against a build of the PARENT COMMIT.
#
# THEY ARE PR-SCOPED, AND THAT IS THE WHOLE LIFECYCLE. An entry is live for
# exactly one review — while the change is unmerged and the parent still
# lacks it. The moment it lands, the parent HAS the fix, the probe stops
# diverging, and the entry is SPENT: inert, and pure debris. So a waiver is
# added with the PR that needs it and removed with the next one.
#
# Bought (#1016). `sign_extend`'s waiver was written for #971 Phase B and left
# behind when #1015 landed. From that commit on, the "baseline" contained the
# guard, so `sign_extend of ["x", 8]` answered a deterministic 0 on BOTH
# sides — and the waiver's proof, which requires the BASELINE to be unstable,
# could never hold again. The documented pre-land command
# (`bash tools/strict_differential.sh <parent-build>`) therefore returned
# FAIL on a clean tree for every run between #1015 and #1016, while the half
# it exists to measure was green: `identical-when-off: 63 differing: 0`.
# A gate that always fails is ignored exactly as fast as one that never fires.
# The eleven #1007 waivers were added the same day and would have started
# rotting the moment #1018 merged; the STALE WAIVER check below caught all
# eleven on the first post-merge run, which is what it is for.
#
# CI never evaluates any of this: it runs --no-baseline, which skips every
# `[ -n "$BASE" ]` block. So an entry left here is invisible until the next
# person runs the two-binary mode by hand and is met with someone else's
# expired paperwork.
#
# Currently empty, deliberately. Add an entry ONLY alongside the change that
# needs it, in the group whose proof matches the claim being made:
#   EXPECTED_DIVERGE_UNSTABLE — "the old answer was undefined and not even
#     stable across runs" (proof: two baseline runs must DIFFER)
#   EXPECTED_DIVERGE_FIXED    — "the old answer was stable and wrong"
#     (proof: two baseline runs must AGREE, and the new answer must be 0)
# #971 (NaN enumeration) ALMOST added one, and the second look is the reason
# both lists are empty. matmul's BUFFER path stores the kernel's raw inf-inf
# NaN, and a raw NaN in a buffer is not a number the program can see — its bit
# pattern is a NaN-boxed slot tag, so `r[0]` reads back as `null` (0xFFF8...
# is SLOT_NULL_BITS). Collapsing it to 0 the way the list path does looked
# like a free fix, and it was written, waived here as EXPECTED_DIVERGE_FIXED,
# and proven. But a proven waiver is still a hole in the ONE claim this whole
# tool exists to make — "with the flag off, nothing changed" — and that claim
# is worth more than the incidental fix. The strict half now raises through
# STRICT_DOMAIN, which cannot touch the soft path, `r[0]` still reads `null`
# with the flag off, and the pre-existing `null` read is recorded in
# ROADMAP.md as its own change with its own differential. Nothing is waived.
EXPECTED_DIVERGE_UNSTABLE=""
EXPECTED_DIVERGE_FIXED=""
EXPECTED_DIVERGE="$EXPECTED_DIVERGE_UNSTABLE
$EXPECTED_DIVERGE_FIXED"

# Guards that CANNOT be probed, named with the reason. Without this list they
# would sit in "GUARDED BUT UNPROBED" forever and train the reader to ignore
# that section — which is how a real gap gets missed.
#
#   (currently empty)
#
#   store_update was waived here until #1006. The waiver's reason was that its
#   key-type guard was unreachable — store_update called store_delete first
#   with the same [handle, collection, key] triple, so a bad key was rejected
#   there and the raise named store_delete. #1006 removed that delegation (the
#   delete had to be split so a failed replace could be undone), which made
#   both of store_update's guards reachable and self-naming. The waiver named
#   its own trigger — "if it is ever made reachable it must gain a probe here"
#   — and this is that: two probes below, no waiver.
UNPROBEABLE=""

run_capture() {   # <binary> <env-strict|-> <file>  -> prints "rc\nstdout+stderr"
    local bin="$1" strict="$2" f="$3" out rc
    if [ "$strict" = "-" ]; then
        out="$("$bin" "$f" 2>&1)"; rc=$?
    else
        out="$(EIGS_STRICT="$strict" "$bin" "$f" 2>&1)"; rc=$?
    fi
    printf '%s\n%s' "$rc" "$out"
}

# Did this run MEASURE anything? A guard raise exits 1. Exit 126/127 means the
# process could not be executed, and >= 128 means it was killed by a signal —
# neither is a statement about a guard, and scoring them as one is how a loaded
# box produces a finding about code that is fine. Returns the reason, or "" when
# the run is a legitimate measurement.
#
# WHAT $? CAN AND CANNOT SAY. A shell reports a signalled child as 128+N and a
# child that called exit(128+N) as the same number; POSIX exposes no way to
# tell them apart from `$?` alone — only a waitpid caller sees WIFSIGNALED. So
# this names the signal it WOULD be and says which reading it is taking. That
# reading is safe HERE for a reason worth writing down: the probe programs
# never call `exit`, and the runtime's own exits are 0, 1 and 2 — so 126, 127
# and >= 128 cannot be the program's own choice in this harness. The argument
# is what makes the classification sound; it is not a general one, and a probe
# row that ever calls `exit of N` breaks it.
# (Seen on this box 2026-09-07: a suite child died with 143 = SIGTERM, sent
# from outside the suite entirely. Nothing in this script signals anything.)
sig_name() {   # <signal number> -> TERM / KILL / ... or the number
    case "$1" in
        1) printf 'HUP' ;;  2) printf 'INT' ;;  3) printf 'QUIT' ;;
        6) printf 'ABRT' ;; 8) printf 'FPE' ;;  9) printf 'KILL' ;;
        11) printf 'SEGV' ;; 13) printf 'PIPE' ;; 15) printf 'TERM' ;;
        24) printf 'XCPU' ;; 25) printf 'XFSZ' ;;
        *) printf '%s' "$1" ;;
    esac
}
run_did_not_measure() {   # <rc>
    case "$1" in
        126|127) printf 'the process could not be executed (exit %s)' "$1" ;;
        1[3-9][0-9]|12[89]) printf 'killed by SIG%s (%s = 128+%s) — a crash, not a guard' \
            "$(sig_name "$(( $1 - 128 ))")" "$1" "$(( $1 - 128 ))" ;;
        *) printf '' ;;
    esac
}

# --------------------------------------------------------------- selftest
# What this proves, and what it deliberately does not. It measures the
# MATCHERS this script decides with — not a guard, not the build. It exists
# because #1120's flake was invisible to every check in here: the tool went
# red on a green tree ~10% of the time under load, and the accusation it
# printed was refuted by its own diagnostic two lines later.
#
# Four things, and the last is the one that makes the rest non-vacuous:
#   1. the three matchers answer correctly on ordinary input (positive AND
#      negative cases — a matcher that always says yes passes only the first);
#   2. they answer correctly on a capture larger than the pipe buffer, which
#      is where the construct they replaced fails;
#   3. a deliberately WRONG matcher fails the same battery, so the battery is
#      shown to discriminate rather than to accept anything;
#   4. the construct they replaced — `printf | grep -q` under pipefail — is
#      shown to report NO-MATCH on input the shell matcher matches. That is
#      #1120 itself, reproduced deterministically. The pad grows until the
#      writer must block, so the assertion does not depend on knowing any
#      platform's pipe-buffer size.
if [ "$SELFTEST" = "1" ]; then
    echo "== strict_differential selftest (#1120: the matchers, not the guards) =="
    st_n=0; st_fail=0
    st_ok()  { st_n=$((st_n + 1)); printf '  ok    %s\n' "$1"; }
    st_bad() { st_n=$((st_n + 1)); st_fail=$((st_fail + 1)); printf '  FAIL  %s\n' "$1"; }
    st_is()  {   # <want-status> <got-status, pass $? here> <label>
        if [ "$1" = "$2" ]; then st_ok "$3"; else st_bad "$3 (got $2, want $1)"; fi
    }

    hay="1
Error line 1: abs: expected a number
     1 | print of (abs of \"x\")"
    str_has "$hay" "abs: expected";  st_is 0 $? "str_has finds a guard message in a capture"
    str_has "$hay" "ceil: expected"; st_is 1 $? "str_has rejects a message that is not there"

    lines="src/vm.c
src/jit.c"
    str_has_line "$lines" "src/jit.c"; st_is 0 $? "str_has_line finds a whole line"
    str_has_line "$lines" "src/jit";   st_is 1 $? "str_has_line rejects a PREFIX of a line"
    str_has_line "$lines" "vm.c";      st_is 1 $? "str_has_line rejects a SUFFIX of a line"

    str_has_word " abs ceil " "ceil";  st_is 0 $? "str_has_word finds a name in a space list"
    str_has_word " abs ceil " "ceil2"; st_is 1 $? "str_has_word rejects a longer name"
    str_has_word " abs ceil " "eil";   st_is 1 $? "str_has_word rejects an infix"

    # (2) and (4): ONE input, both forms, same needle.
    # The capture has the SHAPE a real one has — the guard message on a
    # complete first line, more text behind it — because both halves matter.
    # The newline is what lets a line-oriented reader decide early (with no
    # newline anywhere, grep buffers the whole input and the race disappears,
    # which is how the first draft of this check passed at 4 MB); the bulk is
    # what makes the writer block. Grow until the race shows, so nothing here
    # depends on knowing a platform's pipe-buffer size.
    _chunk='xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
'
    pad_len=262144; racy=0; big=""
    while :; do
        _pad="$_chunk"
        while [ "${#_pad}" -lt "$pad_len" ]; do _pad="$_pad$_pad"; done
        big="Error line 1: abs: expected a number
$_pad"
        printf '%s' "$big" | grep -qF "abs: expected"
        racy=$?
        [ "$racy" != "0" ] && break
        [ "$pad_len" -ge 8388608 ] && break
        pad_len=$((pad_len * 4))
    done
    str_has "$big" "abs: expected"
    st_is 0 $? "str_has finds the needle in a ${#big}-byte capture"
    if [ "$racy" != "0" ]; then
        st_ok "the construct this replaced reports NO-MATCH (rc=$racy) on that same capture — #1120 reproduced"
    else
        st_bad "\`printf | grep -q\` still matched a ${#big}-byte capture, so this selftest
        is no longer demonstrating the #1120 race. Raise the ceiling above this
        platform's pipe-buffer size (or its reader stopped exiting early). The
        shell matchers above are required either way — do NOT bring the
        pipeline back on the strength of this line."
    fi

    # (3) the battery must be able to fail: a broken matcher must not pass it.
    str_has_broken() { case "$1" in "$2"*) return 0 ;; esac; return 1 ; }
    if str_has_broken "$hay" "abs: expected"; then
        st_bad "a prefix-only matcher passed the positive case — the battery does not discriminate"
    else
        st_ok "a deliberately broken matcher fails this battery (the battery discriminates)"
    fi

    # Vacuity: a selftest that measured nothing is not a pass.
    if [ "$st_n" -lt 11 ]; then
        echo "  VACUOUS: only $st_n checks ran — the selftest itself broke"
        st_fail=$((st_fail + 1))
    fi
    echo "  checks=$st_n failed=$st_fail"
    verdict_printed=1
    [ "$st_fail" = "0" ] && { echo "OK"; exit 0; }
    echo "FAIL"; exit 1
fi

# ------------------------------------------------------ evidence for next time
# #1120 stayed unnamed for a day because a red verdict carried 70 truncated
# characters of the capture it disagreed with, and the failing run's own bytes
# were gone by the time anyone read the log. Any run that finds SOMETHING now
# writes the whole capture, its exit status, the pattern that was matched
# against, and — the line that names a harness bug on sight — whether the
# pattern is in those bytes after all. A green run writes nothing and leaves
# no directory behind. The path carries the PID, so two suites in two
# worktrees cannot land in the same place.
EV_DIR="${EIGS_DIFF_EVIDENCE:-${TMPDIR:-/tmp}/eigs-strictdiff-evidence.$$}"
ev_n=0
record_evidence() {   # <kind> <name> <pattern> <capture: "rc\nbytes">
    mkdir -p "$EV_DIR" 2>/dev/null || return 0
    ev_n=$((ev_n + 1))
    local safe="${2//[^A-Za-z0-9_.-]/_}" file _ev_why
    file="$(printf '%s/%03d-%s-%s.txt' "$EV_DIR" "$ev_n" "$1" "$safe")"
    {
        printf 'kind:     %s\n' "$1"
        printf 'name:     %s\n' "$2"
        printf 'pattern:  %s\n' "$3"
        printf 'exit:     %s\n' "${4%%$'\n'*}"
        _ev_why="$(run_did_not_measure "${4%%$'\n'*}")"
        if [ -n "$_ev_why" ]; then
            printf 'status:   %s\n' "$_ev_why"
            printf '          (a shell reports a signalled child and an exit(128+N) as\n'
            printf '           the same number; the probe programs never call exit and\n'
            printf '           the runtime exits 0/1/2, so this reads as a signal.)\n'
        else
            printf 'status:   ordinary exit — the process ran to completion\n'
        fi
        printf 'bytes:    %s (whole capture, including the exit-status line)\n' "${#4}"
        if [ -n "$3" ] && str_has "$4" "$3"; then
            printf 'recheck:  PRESENT — the pattern IS in the bytes below.\n'
            if [ "$1" = "misattributed" ]; then
                printf '          This verdict and its own evidence DISAGREE, so it is a\n'
                printf '          HARNESS bug, not a finding about a guard. See #1120: a\n'
                printf '          matcher that goes through a pipe under `set -o pipefail`\n'
                printf '          reports no-match whenever the reader exits first.\n'
            else
                printf '          (Consistent with this verdict: the guard did name itself\n'
                printf '           before whatever is recorded above happened to the run.)\n'
            fi
        elif [ -n "$3" ]; then
            printf 'recheck:  ABSENT — the pattern is genuinely not in the bytes below.\n'
        fi
        printf -- '--- raw capture, verbatim (first line is the exit status) ---\n'
        printf '%s\n' "$4"
    } > "$file" 2>/dev/null
}

# rc is initialised ONCE, here, before any check can run. It used to be
# assigned rc=0 down in the summary block — AFTER the cross-check section had
# already set rc=1 — so a STALE UNPROBEABLE WAIVER finding printed and the
# script still exited 0. A check that fires and returns success is the exact
# false green this repo keeps a hook for, and it was living in the tool built
# to prevent them. Do not reset rc anywhere below.
rc=0
n_probe=0 n_ident=0 n_differ=0 n_raise=0 n_silent=0 n_waived=0
waived_seen=""
n_pin=0 n_pin_ok=0 n_pin_broke=0 n_misattr=0
n_unrun=0 unrun_list=""
differ_list="" silent_list="" pin_list="" misattr_list=""
n_skipped=0 skipped_list=""

# Which guarded builtins live in a VARIANT-ONLY translation unit? #1007 put
# the first ARG_GUARDs in ext_gfx.c, which `make` compiles out entirely, so a
# probe for one of them in a default build fails as "undefined variable" — a
# silent guard for a reason that has nothing to do with the guard.
#
# The population is derived from the source (same extractor as the
# cross-check), and PRESENCE is decided by RUNNING the name, not by reading
# `--api`. `--api` reports the documented surface, not the linked one: a
# release binary lists `extension gfx gfx_open` while `gfx_open` is an
# undefined variable at runtime (measured 2026-08-20). Executing costs one
# process per variant-only name — three today — and cannot disagree with the
# build.
# WHICH FILES ARE VARIANT-ONLY? Ask the build system, not a hand-list. A file
# the RELEASE variant does not compile is variant-only by definition, and
# `make print-SRC_V_release` is the Makefile's own post-expansion answer.
#
# The first version hard-coded /ext_(gfx|http|db|net)\.c$/ and therefore
# missed `model_infer.c`, which is just as variant-only (EIGENSCRIPT_EXT_MODEL)
# — `eigen_eval_loss` reported as "raised by the wrong guard: undefined
# variable" in a default build. A sibling list of file names drifts from the
# Makefile exactly the way §1 of mechanical-gates describes.
# The guarded-name extractor, shared by the variant-only scan and the
# cross-check so the two cannot disagree about what a guard looks like.
# Every strict spelling counts: ARG_GUARD and its taped forms, the coercion
# shape STRICT_REQUIRE (#971 Phase B — sites the classifier cannot see), the
# domain shape STRICT_DOMAIN and the NaN sources num_guard_named (#971
# NaN enumeration). The first quoted string in the call is the name.
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

release_srcs="$(make print-SRC_V_release 2>/dev/null | tr ' ' '\n' | sed '/^$/d' | sort -u)"
variant_only=""
if [ -n "$release_srcs" ]; then
    for f in src/*.c; do
        str_has_line "$release_srcs" "$f" && continue
        variant_only="$variant_only
$(extract_guard_names "$f")"
    done
    variant_only="$(printf '%s\n' "$variant_only" | sed '/^$/d' | sort -u)"
else
    # No answer from make: fall back to running every probe rather than
    # silently skipping the whole variant-only set (a skip that cannot be
    # justified is worse than a probe that fails loudly).
    echo "  NOTE: 'make print-SRC_V_release' gave nothing — variant-only detection off"
fi

absent_here=""
for v in $variant_only; do
    printf 'print of %s\n' "${v%%/*}" > "$TMP/present.eigs"
    # Capture, THEN match. Under `set -o pipefail` a pipeline reports the
    # rightmost nonzero status, and the probe program exits 1 by design when
    # the name is undefined — so `prog | grep -q` returned 1 on a successful
    # match and every absent builtin read as present.
    _present_out="$("$NEW" "$TMP/present.eigs" 2>&1)"; _present_rc=$?
    # A presence check that did not RUN is not a "present" answer. Assuming
    # present sends the probe in, where it dies "undefined variable" and is
    # scored RAISED BY THE WRONG GUARD — an environment fact charged to a
    # guard, which is the #1120 shape arriving by a second road. Same bucket
    # as an unrun probe: named, red, and not a finding about the code.
    _why="$(run_did_not_measure "$_present_rc")"
    if [ -n "$_why" ]; then
        n_unrun=$((n_unrun + 1))
        unrun_list="$unrun_list
    presence check for ${v%%/*} — $_why"
        record_evidence unrun "presence:${v%%/*}" "" "$_present_rc
$_present_out"
        continue
    fi
    case "$_present_out" in
        *"undefined variable"*) absent_here="$absent_here ${v%%/*}" ;;
    esac
done

# A probe is runnable unless its builtin is a variant-only one this build
# does not contain.
probe_builtin_present() {
    local first="${1%%/*}"
    case " $absent_here " in *" $first "*) return 1 ;; esac
    return 0
}

while IFS='|' read -r who prog expect; do
    [ -z "${who:-}" ] && continue
    expect="${expect:-$who: expected}"
    # A probe for a builtin this build does not contain would "not raise" for
    # the uninteresting reason that the name is undefined, which reads as a
    # guard that went silent. Skip it, and COUNT the skip — a probe that
    # quietly stops running is the vacuity this tool exists to prevent.
    if ! probe_builtin_present "$who"; then
        n_skipped=$((n_skipped + 1))
        skipped_list="$skipped_list $who"
        continue
    fi
    n_probe=$((n_probe + 1))
    f="$TMP/p.eigs"; printf '%b\n' "$prog" > "$f"

    if [ -n "$BASE" ]; then
        a="$(run_capture "$BASE" - "$f")"
        b="$(run_capture "$NEW" - "$f")"
        if [ "$a" = "$b" ]; then
            n_ident=$((n_ident + 1))
        else
            # A waived divergence still gets its strict half measured
            # below — waiving the default-path comparison must not quietly
            # drop the probe from the loudness count too.
            if str_has_line "$EXPECTED_DIVERGE" "$who"; then
                n_waived=$((n_waived + 1))
                waived_seen="$waived_seen $who"
            else
                n_differ=$((n_differ + 1))
                differ_list="$differ_list
    $who
      baseline: $(printf '%s' "$a" | tr '\n' ' ' | cut -c1-90)
      new     : $(printf '%s' "$b" | tr '\n' ' ' | cut -c1-90)"
            fi
        fi
    fi

    s="$(run_capture "$NEW" 1 "$f")"
    s_rc="${s%%$'\n'*}"
    why="$(run_did_not_measure "$s_rc")"
    if [ -n "$why" ]; then
        n_unrun=$((n_unrun + 1))
        record_evidence unrun "$who" "$expect" "$s"
        unrun_list="$unrun_list
    $who — $why: $(printf '%s' "$s" | tr '\n' ' ' | cut -c1-70)"
    elif [ "$s_rc" != "0" ]; then
        # A nonzero exit is NOT enough. A probe that raises somewhere else
        # entirely — an arity error before the type guard, an unconditional
        # rt_error higher up — scores as coverage while testing nothing. So
        # the message must NAME this guard: the builtin, and the word the
        # ARG_GUARD macro emits. (For the shared tensor helpers, `who` is a
        # slash-joined set like "sqrt/exp/log/negative", so the first
        # component is matched.)
        # Match "<name>: expected", the exact shape ARG_GUARD emits. Bare
        # `grep -F "$name"` was VACUOUS: the runtime echoes the offending
        # source line under the error, and that line always contains the
        # builtin being called — so a probe rewritten to call something else
        # entirely still matched. Demonstrated by a blind review: probe `abs`
        # rewritten as `cos of "abs"` scored as coverage.
        # The FULL who, not its first component: the shared tensor helpers
        # are registered as "sqrt/exp/log/negative" and emit that verbatim,
        # so trimming at the slash made the matcher miss its own message.
        # str_has, never a pipeline. This was `printf ... | grep -qF`, and
        # under `set -o pipefail` that is the #1120 race: grep -q exits on its
        # first match and closes the pipe, the still-writing printf takes
        # SIGPIPE and exits 141, pipefail reports 141 — no match — while grep
        # itself returned 0. The probe was then scored MISATTRIBUTED with a
        # diagnostic quoting the message the matcher had just matched.
        # Measured with the pipe form restored here: 18 red runs in 186 under
        # load, over 18 different probes. Nothing about this decision may go
        # through a pipe; see the matcher block near the top, and --selftest,
        # which reproduces the race deterministically.
        if str_has "$s" "$expect"; then
            n_raise=$((n_raise + 1))
        else
            n_misattr=$((n_misattr + 1))
            record_evidence misattributed "$who" "$expect" "$s"
            misattr_list="$misattr_list
    $who — raised, but not by its own guard: $(printf '%s' "$s" | tr '\n' ' ' | cut -c1-70)"
        fi
    else
        n_silent=$((n_silent + 1))
        record_evidence silent "$who" "$expect" "$s"
        silent_list="$silent_list
    $who — still silent under EIGS_STRICT=1: $(printf '%s' "$s" | tr '\n' ' ' | cut -c1-70)"
    fi
done <<<"$PROBES"

while IFS='|' read -r label prog; do
    [ -z "${label:-}" ] && continue
    n_pin=$((n_pin + 1))
    f="$TMP/pin.eigs"; printf '%s\n' "$prog" > "$f"
    s="$(run_capture "$NEW" 1 "$f")"
    why="$(run_did_not_measure "${s%%$'\n'*}")"
    if [ -n "$why" ]; then
        n_unrun=$((n_unrun + 1))
        record_evidence unrun "pin:$label" "" "$s"
        unrun_list="$unrun_list
    pin: $label — $why"
    elif [ "${s%%$'\n'*}" = "0" ]; then
        n_pin_ok=$((n_pin_ok + 1))
    else
        n_pin_broke=$((n_pin_broke + 1))
        record_evidence pin-broken "$label" "" "$s"
        pin_list="$pin_list
    $label — strict RAISED on a documented answer: $(printf '%s' "$s" | tr '\n' ' ' | cut -c1-70)"
    fi
done <<<"$PINS"

# ------------------------------------------------------------------- sweep
# A DISCOVERY instrument, not a gate — and it exists because of a structural
# hole a blind review found in the cross-check below.
#
# That cross-check derives its expected probe set from the names appearing in
# an `ARG_GUARD(` call. So it can only ever measure builtins that were ALREADY
# converted: a builtin that launders a wrong-typed argument and was never
# touched is invisible to it BY CONSTRUCTION. That is the sibling-list disease
# one level up — the check shares the very assumption that is drifting.
#
# It cost real coverage. `sum of "hello"` was 0 under strict while
# `sqrt of "hello"` raised — same file, same commit — and nothing here could
# say so, because `sum` had no guard and therefore no probe.
#
# This sweep asks the opposite question: hand EVERY builtin a wrong-typed
# argument and list the ones that answer QUIETLY under strict. Its output is a
# list for a human to read, not a pass/fail — most entries are legitimate
# (a builtin that genuinely takes a string, a documented coercion). It is the
# instrument that finds candidates; classification still happens by reading.
#
# Side-effecting and blocking builtins are skipped by name, listed here so the
# exclusion is visible rather than implied.
if [ "${1:-}" = "--sweep" ] || [ "${2:-}" = "--sweep" ]; then
    SKIP='^(exit|throw|usleep|sleep|task_sleep|screen_end|screen_clear|screen_render|input|read_line|raw_key|http_serve|serve|listen|gfx_.*|audio_.*|spawn|task_spawn|task_yield|task_recv|proc_.*|exec|system|rm|rmdir|remove_file|rename|chdir|mkdir|write.*|store_.*|db_.*|stream_.*|tensor_save|flush|assert)$'
    echo "== wrong-typed-argument sweep (discovery, not a gate) =="
    quiet=0; loud=0; skipped=0
    for b in $("$NEW" --api --json 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print("\n".join(d.get("builtins",[])))'); do
        # bash's own regex match: no fork, no pipe. $SKIP is deliberately
        # unquoted here — quoting it inside [[ =~ ]] makes it a literal.
        if [[ "$b" =~ $SKIP ]]; then skipped=$((skipped+1)); continue; fi
        # A DICT is the probe value: it is a wrong argument for very nearly
        # every builtin in the surface, where a string is the RIGHT argument
        # for dozens (sha256, read_text, file_exists...) and those all read as
        # false "quiet" rows. Picking the probe type is most of this
        # instrument's precision.
        printf 'print of (%s of ({"eigs_sweep_probe": 1}))\n' "$b" > "$TMP/sw.eigs"
        out="$(EIGS_STRICT=1 timeout 5 "$NEW" "$TMP/sw.eigs" 2>&1)"; src=$?
        if [ "$src" = "0" ]; then
            quiet=$((quiet+1))
            printf '  QUIET  %-24s -> %s\n' "$b" "$(printf '%s' "$out" | head -1 | cut -c1-40)"
        else
            loud=$((loud+1))
        fi
    done
    echo "  quiet=$quiet loud=$loud skipped=$skipped (skipped = side-effecting/blocking, see SKIP above)"
    echo "  A QUIET row is a CANDIDATE, not a defect: read the function before acting."
    verdict_printed=1   # the sweep's verdict IS its listing; it is not a gate
    exit 0
fi

# --------------------------------------------------- valid-input differential
n_valid=0 n_valid_same=0 valid_list=""
if [ -n "$BASE" ]; then
    while IFS= read -r prog; do
        [ -z "$prog" ] && continue
        n_valid=$((n_valid + 1))
        printf '%b\n' "$prog" > "$TMP/v.eigs"
        for mode in - 1; do
            a="$(run_capture "$BASE" "$mode" "$TMP/v.eigs")"
            b="$(run_capture "$NEW"  "$mode" "$TMP/v.eigs")"
            if [ "$a" != "$b" ]; then
                valid_list="$valid_list
    [strict=${mode}] $prog
      baseline: $(printf '%s' "$a" | tr '\n' ' ' | cut -c1-80)
      new     : $(printf '%s' "$b" | tr '\n' ' ' | cut -c1-80)"
            fi
        done
        [ -z "$valid_list" ] && n_valid_same=$((n_valid_same + 1))
    done <<<"$VALID"
fi

# ------------------------------------------------ cross-check the probe list
# The guarded-name set is DERIVED from the source. A guard whose builtin has
# no probe is unmeasured, and an unmeasured guard is indistinguishable from
# one that does not fire.
# The name extractor JOINS continuation lines. Its first version read one
# physical line, so a guard wrapped across two — condition on the first line,
# strings on the second, which is how the long ones are formatted — yielded no
# name at all and vanished from the expected-probe set. That is precisely the
# "guarded but unprobed" hole this cross-check exists to detect, living inside
# the cross-check. Caught when three freshly added guards reported as STALE
# PROBES rather than as newly covered ones.
guarded="$(extract_guard_names src/*.c | sed '/^$/d' | sort -u)"
probed="$(printf '%s\n' "$PROBES" | cut -d'|' -f1 | sed '/^$/d' | sort -u)"

# Names absent from THIS build (computed above by execution) are excused for
# this run only — never by a waiver anyone maintains.
# The `grep -vxF` below is a SET DIFFERENCE, not a verdict, and it is the
# exception the #1120 rule allows: `-v` has no early exit, so it consumes its
# input to EOF and cannot SIGPIPE the writer. The same is true of the `grep -c`
# in the summary. Anything that decides pass/fail uses str_has* instead.
missing="$(comm -23 <(printf '%s\n' "$guarded") <(printf '%s\n' "$probed") \
    | grep -vxF -f <(printf '%s\n' $UNPROBEABLE $absent_here) || true)"
stale="$(comm -13 <(printf '%s\n' "$guarded") <(printf '%s\n' "$probed"))"
# A waived-as-unprobeable name that is no longer guarded at all is a stale
# waiver: the guard it excused is gone.
for u in $UNPROBEABLE; do
    str_has_line "$guarded" "$u" || {
        echo "  STALE UNPROBEABLE WAIVER: $u is waived but carries no guard"; rc=1; }
done

echo "== #971 strict differential =="
echo "  probes=$n_probe pins=$n_pin"
if [ "$n_skipped" -gt 0 ]; then
    # Not a failure: these guards are compiled out of THIS build. Named, so a
    # reader can see which are unmeasured here and run the variant build.
    echo "  probes skipped (builtin not in this build): $n_skipped —$skipped_list"
fi
if [ -n "$BASE" ]; then
    echo "  identical-when-off: $n_ident   differing: $n_differ   waived: $n_waived"
else
    echo "  identical-when-off: SKIPPED (no baseline binary given)"
fi
echo "  raises-under-strict: $n_raise   silent: $n_silent   misattributed: $n_misattr"
[ "$n_unrun" -gt 0 ] && echo "  probes that did not run: $n_unrun"
echo "  answer-pins held: $n_pin_ok   broken: $n_pin_broke"
if [ -n "$BASE" ]; then
    echo "  valid-input rows unchanged in BOTH modes: $((n_valid * 2 - $(printf '%s' "$valid_list" | grep -c '\[strict=' || true))) / $((n_valid * 2))"
fi

# NOTE: rc is NOT reset here. It is initialised once above, because the
# cross-check section runs BEFORE this block and can already have set it.
[ -n "$differ_list" ] && { echo "  DIFFERING (the default path was NOT preserved):$differ_list"; rc=1; }
[ -n "$silent_list" ] && { echo "  SILENT UNDER STRICT:$silent_list"; rc=1; }
[ -n "$misattr_list" ] && { echo "  RAISED BY THE WRONG GUARD (probe does not reach its target):$misattr_list"; rc=1; }
# NOT a finding about a guard, and said in those words so the reader goes to the
# machine and not to the probe table. Still red: an unmeasured probe leaves the
# invariant unproven, and this tool does not go green on unmeasured population.
[ -n "$unrun_list" ]  && { echo "  DID NOT RUN (the environment, not a guard — nothing is retried):$unrun_list"; rc=1; }
[ -n "$valid_list" ]  && { echo "  VALID INPUT CHANGED (a guard is too broad, or a split reordered a real branch):$valid_list"; rc=1; }
[ -n "$pin_list" ]    && { echo "  PIN BROKEN (the reform overshot into a documented answer):$pin_list"; rc=1; }
[ -n "$missing" ]     && { echo "  GUARDED BUT UNPROBED:"; printf '    %s\n' $missing; rc=1; }
[ -n "$stale" ]       && { echo "  PROBED BUT NO LONGER GUARDED (stale probe):"; printf '    %s\n' $stale; rc=1; }

# The waiver is ASSERTED, not asserted-about. sign_extend's justification is
# "the baseline behaviour was undefined, and not even stable across runs", so
# the harness proves that half rather than asking to be believed: run the
# BASELINE twice on the same probe and require the two results to differ. If
# they ever stop differing, the UB claim is wrong and the waiver must be
# re-argued. (This probe is therefore deliberately kept OUT of the identity
# comparison — a nondeterministic fixture does not belong in a differential
# as an ordinary row.)
# The DETERMINISTIC group (#1007) claims the opposite: the old answer was
# stable and simply wrong — a reported success for an argument the builtin
# could not honour — and the new one is that builtin's documented failure
# answer. So its proof is the mirror image: the two baseline runs must AGREE
# (a wobbling baseline would mean the "stable and wrong" reading is itself
# wrong), and the NEW binary must answer 0. Neither half is implied by the
# other, and neither is the instability check.
if [ -n "$BASE" ]; then
    for w in $EXPECTED_DIVERGE_FIXED; do
        wprog="$(probe_prog_for "$w")"
        [ -z "$wprog" ] && continue
        printf '%b\n' "$wprog" > "$TMP/w.eigs"
        probe_builtin_present "$w" || { echo "  waiver not exercised: $w is not in this build"; continue; }
        d1="$(run_capture "$BASE" - "$TMP/w.eigs")"
        d2="$(run_capture "$BASE" - "$TMP/w.eigs")"
        dn="$(run_capture "$NEW" - "$TMP/w.eigs")"
        if [ "$d1" != "$d2" ]; then
            echo "  WAIVER UNPROVEN: $w — the baseline is NOT stable across runs"
            echo "                   ($(printf '%s' "$d1" | tr '\n' ' ') vs $(printf '%s' "$d2" | tr '\n' ' ')),"
            echo "                   so 'the old answer was deterministic and wrong' does not hold."
            rc=1
        elif [ "$dn" != "0
0" ]; then
            echo "  WAIVER UNPROVEN: $w — the new answer is not the documented failure value"
            echo "                   (got $(printf '%s' "$dn" | tr '\n' ' '), want rc 0 and 0)."
            rc=1
        else
            echo "  waiver proven: $w baseline stable at $(printf '%s' "$d1" | tr '\n' ' ' | cut -c1-40), new answers 0"
        fi
    done
fi

if [ -n "$BASE" ]; then
    for w in $EXPECTED_DIVERGE_UNSTABLE; do
        wprog="$(probe_prog_for "$w")"
        if [ -n "$wprog" ]; then
            printf '%b\n' "$wprog" > "$TMP/w.eigs"
            r1="$(run_capture "$BASE" - "$TMP/w.eigs")"
            r2="$(run_capture "$BASE" - "$TMP/w.eigs")"
            if [ "$r1" = "$r2" ]; then
                echo "  WAIVER UNPROVEN: $w — two baseline runs agreed"
                echo "                   ($(printf '%s' "$r1" | tr '\n' ' ')),"
                echo "                   so the 'undefined, unstable' justification"
                echo "                   for waiving it does not hold. Re-argue it."
                rc=1
            else
                echo "  waiver proven: $w baseline is run-to-run unstable"
                echo "    run 1: $(printf '%s' "$r1" | tr '\n' ' ' | cut -c1-60)"
                echo "    run 2: $(printf '%s' "$r2" | tr '\n' ' ' | cut -c1-60)"
            fi
        fi
    done
fi

# An exemption that no longer fires must FAIL, not pass quietly: it means
# the thing it waived changed shape, which is exactly when a stale waiver
# starts covering something nobody agreed to.
if [ -n "$BASE" ]; then
    for w in $EXPECTED_DIVERGE_UNSTABLE; do
        if ! str_has_word "$waived_seen" "$w"; then
            echo "  SPENT WAIVER: $w is declared divergent but did not differ."
            echo "                Remove the entry. A waiver is PR-scoped: it is live"
            echo "                only while the parent lacks the change, and inert the"
            echo "                moment it lands. Leaving it means the next person to"
            echo "                run the two-binary mode meets expired paperwork —"
            echo "                which is how sign_extend kept this tool red from"
            echo "                #1015 to #1016 (see the waiver block at the top)."
            rc=1
        fi
    done
    for w in $EXPECTED_DIVERGE_FIXED; do
        probe_builtin_present "$w" || continue
        if ! str_has_word "$waived_seen" "$w"; then
            echo "  SPENT WAIVER: $w is declared divergent but did not differ."
            echo "                Either the probe no longer reaches the guard, or —"
            echo "                far more likely — the change LANDED and the baseline"
            echo "                now contains it. Remove the entry; a waiver is
                PR-scoped (see the waiver block at the top)." | tr -s " "
            rc=1
        fi
    done
fi

# Vacuity: this script cannot be green having measured nothing.
if [ "$n_probe" -lt 55 ] || [ "$n_pin" -lt 14 ] || { [ -n "$BASE" ] && [ "$n_valid" -lt 25 ]; }; then
    echo "  VACUOUS: probes=$n_probe pins=$n_pin valid=$n_valid — below a floor; the tables"
    echo "           or the reader broke."
    rc=1
fi
if [ -z "$BASE" ] && [ "$NO_BASELINE" = 0 ]; then
    echo "  INCOMPLETE: no baseline binary, so the load-bearing half of this"
    echo "              differential did not run. Not a pass. (Pass"
    echo "              --no-baseline to accept that deliberately.)"
    rc=1
fi
if [ "$NO_BASELINE" = 1 ]; then
    echo "  NOTE: identical-when-off was NOT measured (no baseline binary)."
    echo "        Before landing a change to any guard, run this with a build"
    echo "        of the parent commit — that half is the safety claim."
fi

# Did the subject hold still? Checked LAST, so it speaks about the whole run.
# A changed binary is not a finding about a guard, and it invalidates every row
# above it — so it is loud, it is red, and it says which reading to take.
if [ -n "$FP_NEW_START" ]; then
    _fp_now="$(bin_fingerprint "$NEW")"
    if [ "$_fp_now" != "$FP_NEW_START" ]; then
        echo "  BINARY CHANGED UNDER THIS RUN: $NEW"
        echo "                 at start: $FP_NEW_START"
        echo "                 at end:   $_fp_now"
        echo "           Probes before and after the change measured DIFFERENT"
        echo "           binaries, so nothing above is a finding about a guard."
        echo "           Something rebuilt or re-pointed the binary mid-run"
        echo "           (src/eigenscript is a hard link to build/<variant>/, so"
        echo "           any 'make' in this worktree does it). Re-run when the"
        echo "           tree is quiet; nothing here is retried."
        rc=1
    fi
fi
if [ -n "$FP_BASE_START" ]; then
    _fp_now="$(bin_fingerprint "$BASE")"
    if [ "$_fp_now" != "$FP_BASE_START" ]; then
        echo "  BASELINE BINARY CHANGED UNDER THIS RUN: $BASE"
        echo "                 at start: $FP_BASE_START"
        echo "                 at end:   $_fp_now"
        echo "           The identical-when-off half compared against a moving"
        echo "           reference; nothing above is a finding about a guard."
        rc=1
    fi
fi

# The evidence a red run leaves behind. #1120 could not be named from the log
# because the log carried 70 truncated characters of a capture that was already
# gone. It is deliberately NOT cleaned up: a red run's bytes outlive the run.
if [ "$ev_n" -gt 0 ]; then
    echo "  evidence: $ev_n capture(s) kept, whole and verbatim, under"
    echo "            $EV_DIR"
    echo "            Each names the pattern it was matched against and says"
    echo "            whether that pattern is in the bytes after all. A file"
    echo "            saying 'recheck: PRESENT' is a HARNESS bug (#1120), not"
    echo "            a finding about a guard. Set EIGS_DIFF_EVIDENCE to place"
    echo "            them somewhere a CI run will keep."
fi

verdict_printed=1
[ "$rc" = 0 ] && echo "OK" || echo "FAIL"
exit $rc
