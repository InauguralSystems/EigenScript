#!/bin/bash
# Parse every tracked *.sh under bash <= 3, and run the macOS shell gates
# under it. bash 3.2 scans <( ) without honouring comments, so -n is not
# enough. No old bash is an announced SKIP, not a pass. Callers read
# portability-parse: oracle-major=N from BASH_VERSINFO, not the banner.
set -u
cd "$(dirname "$0")/.." || { echo "portability-parse: ABORTED: cannot cd" >&2; exit 1; }
FILE_FLOOR="${PORTABILITY_FILE_FLOOR:-110}"
RUN_TARGETS="${PORTABILITY_RUN_TARGETS-tools/docs_claims_check.sh tools/child_exit_check.sh tools/suite_label_check.sh}"
RUN_N="${PORTABILITY_RUN_N:-3}"
MAX="${PORTABILITY_MAX_MAJOR:-3}"
OLD=""; MAJOR=""; TRIED=""; REJ=""
for cand in "${PORTABILITY_BASH:-}" "$HOME/.local/bin/bash32" /usr/local/bin/bash32 /bin/bash /usr/bin/bash; do
    [ -n "$cand" ] || continue
    TRIED="$TRIED $cand"
    [ -x "$cand" ] || continue
    m=$("$cand" -c 'echo ${BASH_VERSINFO[0]}' 2>/dev/null) || m=""
    case "$m" in
        ''|*[!0-9]*) REJ="$REJ $cand(no-BASH_VERSINFO)"; continue ;;
    esac
    if [ "$m" -gt "$MAX" ]; then REJ="$REJ $cand(major=$m)"; continue; fi
    OLD="$cand"; MAJOR="$m"; break
done
indexed="${PORTABILITY_FILES:-}"
if [ -z "$indexed" ]; then indexed=$(git -c safe.directory='*' ls-files '*.sh' 2>/dev/null) || indexed=""; fi
n=0; files=""
for f in $indexed; do
    if [ -f "$f" ]; then files="$files$f "; n=$((n + 1)); fi
done
if [ "${n:-0}" -lt "$FILE_FLOOR" ]; then
    echo "portability-parse: FAIL: git listed $n tracked *.sh (floor $FILE_FLOOR) — the audit is scanning almost nothing"
    exit 1
fi
# GNU userland accepts these convenient flags, but the macOS/BSD tools used by
# the merge queue do not.  This is a row in the portability gate rather than a
# new checker.  shell_lines() is the repository's existing shell lexer: it
# removes comments and skips heredoc bodies before command words are examined.
# Allowlist rows are exact path/kind pairs; every row must consume at least one
# live hit, so deleting the use without deleting its explanation is red.
GNU_FLAG_OUT=$(mktemp "${TMPDIR:-/tmp}/portability_gnu_flags.XXXXXX") || exit 2
trap 'rm -f "$GNU_FLAG_OUT"' EXIT
python3 - $files >"$GNU_FLAG_OUT" <<'PY'
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path.cwd() / "tools"))
from _derive_variants import SEPARATORS, _split_words, _subst_bodies, shell_lines

ALLOW = {
    ("tests/test_ci_portability.sh", "sed -i"): (
        "deliberate portability probe: failure is tested and the BSD-safe branch follows"),
    ("tools/consumer_acceptance.sh", "readlink -f"): (
        "consumer acceptance runs only in the pinned Linux container"),
    ("tests/run_all_tests.sh", "stat -c"): (
        "GNU probe is guarded; failure immediately selects BSD stat -f"),
    ("tools/strict_differential.sh", "stat -c"): (
        "GNU probe is guarded; failure immediately selects BSD stat -f"),
}
CONTROL = {"if", "then", "elif", "else", "do", "while", "until", "!", "time"}
WRAPPERS = {"command", "builtin", "exec", "env", "sudo", "nohup"}


def plain(word):
    if len(word) >= 2 and word[0] == word[-1] and word[0] in "'\"":
        return word[1:-1]
    return word


def commands(text):
    """Yield argv vectors at shell command positions, including substitutions."""
    toks = _split_words(text)
    for tok in toks:
        for body in _subst_bodies(tok):
            yield from commands(body)
    start = 0
    for end in range(len(toks) + 1):
        if end != len(toks) and toks[end] not in SEPARATORS:
            continue
        seg = [plain(x) for x in toks[start:end] if x not in ("<", ">")]
        start = end + 1
        while seg and (seg[0] in CONTROL or
                       ("=" in seg[0] and seg[0].split("=", 1)[0].replace("_", "a").isalnum())):
            seg.pop(0)
        while seg and seg[0] in WRAPPERS:
            seg.pop(0)
            while seg and (seg[0].startswith("-") or "=" in seg[0]):
                seg.pop(0)
        if seg:
            yield seg


def logical_lines(text):
    """Join shell backslash-newline continuations, retaining the first line."""
    first = None
    parts = []
    for lineno, line in shell_lines(text):
        if first is None:
            first = lineno
        # An odd trailing run escapes the newline.  shell_lines has already
        # removed comments, so this is the physical line ending the shell sees.
        trailing = len(line) - len(line.rstrip("\\"))
        if trailing % 2:
            parts.append(line[:-1])
            continue
        parts.append(line)
        yield first, "".join(parts)
        first = None
        parts = []
    if parts:
        yield first, "".join(parts)


def option_words(args, operands=(), attached_operands=()):
    """Yield options, excluding `--` data and option operands.

    attached_operands names short options whose operand may occupy the rest of
    a bundle (for example grep's `-ePATTERN`).
    """
    i = 0
    while i < len(args):
        word = args[i]
        if word == "--":
            break
        if not word.startswith("-") or word == "-":
            i += 1
            continue
        yield word
        if word in operands:
            i += 2
            continue
        if word.startswith("--"):
            i += 1
            continue
        chars = word[1:]
        for pos, char in enumerate(chars):
            if char in attached_operands:
                if pos + 1 == len(chars):
                    i += 1
                break
        i += 1


def grep_has_perl(args):
    for word in option_words(args, ("-e", "-f"), ("e", "f")):
        if word.startswith("--"):
            if word == "--perl-regexp":
                return True
            continue
        for char in word[1:]:
            if char in ("e", "f"):
                break
            if char == "P":
                return True
    return False


def find_has_printf(args):
    i = 0
    one_operand = {"-name", "-path", "-regex", "-iname", "-ipath",
                   "-iregex", "-type", "-user", "-group", "-perm",
                   "-links", "-inum", "-size", "-mtime", "-mmin",
                   "-atime", "-amin", "-ctime", "-cmin", "-newer"}
    while i < len(args):
        word = args[i]
        if word == "--":
            break
        if word == "-printf":
            return True
        if word in one_operand:
            i += 2
            continue
        if word in ("-exec", "-execdir", "-ok", "-okdir"):
            i += 1
            while i < len(args) and args[i] not in (";", "+"):
                i += 1
        i += 1
    return False


def violation(argv):
    cmd = os.path.basename(argv[0])
    args = argv[1:]
    operand_options = {
        "date": ("-f", "--file", "-r", "--reference"),
        "realpath": ("--relative-to", "--relative-base"),
        "stat": ("--format", "--printf"),
        "xargs": ("-a", "--arg-file", "-E", "--eof", "-I", "--replace",
                  "-L", "--max-lines", "-n", "--max-args", "-P",
                  "--max-procs", "-s", "--max-chars"),
    }.get(cmd, ())
    options = list(option_words(args, operand_options))
    if cmd == "realpath" and any(x in ("-m", "-e") for x in options): return "realpath -m/-e"
    if cmd == "readlink" and "-f" in options: return "readlink -f"
    if cmd == "grep" and grep_has_perl(args): return "grep -P"
    if cmd == "date" and "-d" in options: return "date -d"
    if cmd == "stat" and "-c" in options: return "stat -c"
    if cmd == "find" and find_has_printf(args): return "find -printf"
    if cmd == "xargs" and "-r" in options: return "xargs -r"
    sed_options = list(option_words(args, ("-e", "-f"), ("e", "f"))) if cmd == "sed" else []
    if cmd == "sed" and "-i" in sed_options:
        i = args.index("-i")
        # BSD-safe sed supplies the backup suffix as the next argument.  An
        # empty quoted token arrives here as ""; an option or sed program does not.
        if i + 1 == len(args) or args[i + 1] != "": return "sed -i"
    return None


hits = []
for name in sys.argv[1:]:
    text = Path(name).read_text(encoding="utf-8", errors="replace")
    for lineno, line in logical_lines(text):
        for argv in commands(line):
            kind = violation(argv)
            if kind:
                hits.append((name, lineno, kind))

used = set()
bad = 0
allowed = 0
for name, lineno, kind in hits:
    key = (name, kind)
    if key in ALLOW:
        used.add(key); allowed += 1
    else:
        bad += 1
        print(f"gnu-flags: FAIL: {name}:{lineno}: GNU-only {kind}")
population = set(sys.argv[1:])
for key, reason in ALLOW.items():
    # PORTABILITY_FILES deliberately narrows self-test populations.  A waiver
    # is stale only when its owning file was part of this run.
    if key[0] in population and key not in used:
        bad += 1
        print(f"gnu-flags: FAIL: stale allowlist {key[0]} | {key[1]} | {reason}")
print(f"gnu-flags: {'OK' if not bad else 'FAIL'}: files={len(sys.argv)-1} "
      f"allowlisted-hits={allowed} failures={bad}")
raise SystemExit(bool(bad))
PY
GNU_FLAG_RC=$?
cat "$GNU_FLAG_OUT"
rm -f "$GNU_FLAG_OUT"
GNU_FLAG_OUT=""
if [ "${1:-}" = "--selftest" ]; then
    work=$(mktemp -d "${TMPDIR:-/tmp}/portability_parse_selftest.XXXXXX") || exit 2
    trap 'rm -rf "$work"' EXIT
    # Exercise a COPY of a real tools/ script, not a synthetic grammar that
    # might accidentally avoid constructs used by the checked population.
    cp "$0" "$work/plant.sh" || exit 2
    printf '%s\n' '# realpath -m is prose' "sed -i '' 's/x/y/' file" \
        "cat <<'DATA'" 'readlink -f /heredoc/data' 'DATA' 'echo clean' \
        "grep -F -e '-P' f" 'grep -- -P f' "sed -e '-i' f" >> "$work/plant.sh"
    if ! out=$(PORTABILITY_BASH=/bin/bash PORTABILITY_MAX_MAJOR=99 PORTABILITY_FILES="$work/plant.sh" PORTABILITY_FILE_FLOOR=1 PORTABILITY_RUN_TARGETS= PORTABILITY_RUN_N=0 bash "$0" 2>&1); then
        echo "SELFTEST FAILED: clean portability control was rejected"; printf '%s\n' "$out"; exit 1
    elif ! printf '%s\n' "$out" | grep -qF 'portability-parse: OK: files=1 checked=1 failures=0'; then
        echo "SELFTEST FAILED: clean portability control did not parse exactly one file"; printf '%s\n' "$out"; exit 1
    fi
    continued_line=$(($(wc -l < "$work/plant.sh") + 1))
    printf '%s\n' 'find tools \' "-name '*.sh' -printf '%h\\n'" \
        'grep -P x f' 'grep -FP x f' 'realpath -m /planted/path' >> "$work/plant.sh"
    if out=$(PORTABILITY_BASH=/bin/bash PORTABILITY_MAX_MAJOR=99 PORTABILITY_FILES="$work/plant.sh" PORTABILITY_FILE_FLOOR=1 PORTABILITY_RUN_TARGETS= PORTABILITY_RUN_N=0 bash "$0" 2>&1); then
        echo "SELFTEST FAILED: planted GNU-only flag was accepted"; exit 1
    elif ! printf '%s\n' "$out" | grep -F "gnu-flags: FAIL: $work/plant.sh:" | grep -qF 'GNU-only realpath -m/-e'; then
        echo "SELFTEST FAILED: GNU-only plant did not name file:line"; printf '%s\n' "$out"; exit 1
    elif ! printf '%s\n' "$out" | grep -qF "gnu-flags: FAIL: $work/plant.sh:$continued_line: GNU-only find -printf"; then
        echo "SELFTEST FAILED: continued find plant was not reported at its first line"; printf '%s\n' "$out"; exit 1
    elif [ "$(printf '%s\n' "$out" | grep -cF 'GNU-only grep -P')" -ne 2 ]; then
        echo "SELFTEST FAILED: separate and bundled grep -P plants were not both caught"; printf '%s\n' "$out"; exit 1
    fi
    printf '%s\n' '#!/bin/bash' 'if then' > "$work/plant.sh"
    if out=$(PORTABILITY_BASH=/bin/bash PORTABILITY_MAX_MAJOR=99 PORTABILITY_FILES="$work/plant.sh" PORTABILITY_FILE_FLOOR=1 PORTABILITY_RUN_TARGETS= PORTABILITY_RUN_N=0 bash "$0" 2>&1); then
        echo "SELFTEST FAILED: planted shell parse error was accepted"; exit 1
    elif [ "$(printf '%s\n' "$out" | grep -cF "$work/plant.sh does not parse under")" -eq 1 ] &&
         printf '%s\n' "$out" | grep -qF 'portability-parse: FAIL: files=1 checked=1 failures=1'; then
        echo "SELFTEST OK: clean BSD sed/comment/heredoc control passed; GNU flag and shell syntax plants caught"; exit 0
    fi
    echo "SELFTEST FAILED: plant did not produce exactly one parse failure"; printf '%s\n' "$out"; exit 1
fi
if [ "$GNU_FLAG_RC" -ne 0 ]; then exit 1; fi
if [ -z "$OLD" ]; then
    echo "portability-parse: NO OLD BASH ON THIS MACHINE — $n tracked *.sh were NOT parsed by an old shell,"
    echo "portability-parse: and $RUN_N gate(s) were NOT executed under one either."
    echo "portability-parse: looked for, in order:$TRIED"
    echo "portability-parse: rejected by their own version:${REJ:- (none)}"
    echo "portability-parse: every candidate qualifies only when its own BASH_VERSINFO[0] is <= $MAX."
    echo "portability-parse: this machine's /bin/bash reports major version $(/bin/bash -c 'echo ${BASH_VERSINFO[0]}' 2>/dev/null || echo '?')."
    echo "portability-parse: this run proves nothing about bash 3.2. Install one at ~/.local/bin/bash32."
    echo "portability-parse: SKIPPED (announced, not silent): files=$n checked=0 gates-run=0"
    exit 0
fi
ver=$("$OLD" --version 2>/dev/null | head -1)
bad=0; checked=0
err=""; log=""
cleanup() { [ -z "$err" ] || rm -f "$err"; [ -z "$log" ] || rm -f "$log"; }
trap cleanup EXIT
trap 'exit 2' HUP INT TERM
umask 077
err=$(mktemp "${TMPDIR:-/tmp}/portability_parse_err.XXXXXX") || {
    echo "portability-parse: ABORTED: cannot create diagnostic file" >&2; exit 1; }
log=$(mktemp "${TMPDIR:-/tmp}/portability_run.XXXXXX") || {
    echo "portability-parse: ABORTED: cannot create run log" >&2; exit 1; }
for f in $files; do
    checked=$((checked + 1))
    if ! "$OLD" -n "$f" 2>"$err"; then
        bad=$((bad + 1))
        echo "portability-parse: FAIL: $f does not parse under $ver"
        sed 's/^/    | /' "$err" | head -4
    fi
done
if [ "$checked" -ne "$n" ]; then
    echo "portability-parse: FAIL: examined $checked of $n files — the walk dropped some"
    exit 1
fi
echo "portability-parse: oracle=$OLD ($ver)"
echo "portability-parse: oracle-major=$MAJOR"
if [ "$bad" -eq 0 ]; then echo "portability-parse: OK: files=$n checked=$checked failures=0"
else echo "portability-parse: FAIL: files=$n checked=$checked failures=$bad"; fi
run_done=0; run_bad=0
for tgt in $RUN_TARGETS; do
    if [ ! -f "$tgt" ]; then
        echo "portability-run: FAIL: $tgt is in the run list and is not a file — the list names a gate this tree does not have"
        run_bad=$((run_bad + 1)); continue
    fi
    run_done=$((run_done + 1))
    t0=$(date +%s)
    "$OLD" "$tgt" >"$log" 2>&1
    rc=$?; t1=$(date +%s)
    if [ "$rc" -eq 0 ]; then
        echo "portability-run: ok: $tgt  exited 0 under $ver ($((t1 - t0))s)"
    else
        run_bad=$((run_bad + 1))
        echo "portability-run: FAIL: $tgt  exited $rc under $ver — this is what the macOS lane will do"
        sed 's/^/    | /' "$log"
    fi
done
if [ "$run_done" -ne "$RUN_N" ]; then
    echo "portability-run: FAIL: executed $run_done gate(s), $RUN_N declared — the run list shrank"
    exit 1
fi
if [ "$run_bad" -ne 0 ] || [ "$bad" -ne 0 ]; then
    echo "portability: FAIL: files=$n checked=$checked parse-failures=$bad; gates-run=$run_done run-failures=$run_bad"
    exit 1
fi
echo "portability: OK: files=$n checked=$checked parse-failures=0; gates-run=$run_done/$RUN_N run-failures=0 (oracle $ver)"
exit 0
