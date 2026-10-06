#!/usr/bin/env bash
# num_read_check.sh -- #1637: no raw number read without a type check.
#
# A bool is not a number. A C path that reads a Value's `data.num` (or an
# EigsSlot's raw `.d`) without first proving the operand is a number reads a
# bool -- or a string, a list -- as some double, silently. That was the class
# behind both critic rounds on #1637 (slice bounds, list_insert_at, sgd_update's
# learning rate, buf_get's index...). This gate enumerates EVERY such read in
# src/*.c and requires one of:
#   - `X->data.num` / `X.data.num`: the same function, at or before the read,
#     tests `X->type` (or `X.type`) against VAL_NUM, or X came from one of the
#     checked accessors below;
#   - `S.d` (a slot): the same function, at or before the read, tests
#     `slot_is_num(S)` or reads it through `slot_as_double(S, ...)`;
#   - an entry in tools/num_read_allowlist.txt (`file|function|operand|reason`),
#     for reads whose type is proven elsewhere. Every entry must be USED.
# Writes (`X->data.num = ...`, `S.d = ...`) are not reads.
# Prints `num-read: examined=N allowlisted=K violations=V` and exits 1 on any
# violation, an unused allowlist entry, or N == 0.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="${NUM_READ_SRC:-$ROOT/src}"
ALLOW="${NUM_READ_ALLOW:-$ROOT/tools/num_read_allowlist.txt}"
[ -f "$ALLOW" ] || { echo "num-read: FAIL: allowlist $ALLOW missing"; exit 1; }
TMP=$(mktemp "${TMPDIR:-/tmp}/num_read.XXXXXX") || exit 2
trap 'rm -f "$TMP"' EXIT

# Emit one record per read: file|function|operand|line|verdict
for f in "$SRC_DIR"/*.c; do
    case "$(basename "$f")" in jit_smoke.c|embed_smoke.c) continue ;; esac
    awk -v FILE="$(basename "$f")" '
    function base_before(s, pos,    i, c, depth, start) {
        # Walk left from pos-1 over an operand expression: identifiers, ->,
        # ., [..], (..), with bracket balancing.
        i = pos - 1; depth = 0
        while (i >= 1) {
            c = substr(s, i, 1)
            if (c == "]" || c == ")") { depth++; i--; continue }
            if (c == "[" || c == "(") {
                if (depth == 0) break
                depth--; i--; continue
            }
            if (depth > 0) { i--; continue }
            if (c ~ /[A-Za-z0-9_.]/) { i--; continue }
            if (c == ">" && substr(s, i - 1, 1) == "-") { i -= 2; continue }
            break
        }
        b = substr(s, i + 1, pos - i - 1)
        # drop leading casts: (int)x, (long long)x, (uint32_t)x
        while (match(b, /^\([A-Za-z_][A-Za-z0-9_ ]*\**\)/)) b = substr(b, RLENGTH + 1)
        return b
    }
    function guarded(fn_text, b,    q) {
        q = b
        if (index(fn_text, q "->type == VAL_NUM") || index(fn_text, q "->type != VAL_NUM")) return 1
        if (index(fn_text, q ".type == VAL_NUM") || index(fn_text, q ".type != VAL_NUM")) return 1
        if (index(fn_text, "(" q ")->type == VAL_NUM") || index(fn_text, "(" q ")->type != VAL_NUM")) return 1
        if (index(fn_text, "eigs_num_arg(" q ",")) return 1
        # a dispatch on the operand type (switch on Value or AST type)
        if (index(fn_text, "switch (" q "->type)") && (index(fn_text, "case VAL_NUM") || index(fn_text, "case AST_NUM"))) return 1
        if (index(fn_text, q "->type == AST_NUM") || index(fn_text, q "->type != AST_NUM")) return 1
        if (index(fn_text, q " = make_num(") || index(fn_text, q " = make_num_permanent(")) return 1
        return 0
    }
    # A raising guard that names the operand root earlier in the function:
    # one of the raising constructs, with the root inside its next 400 chars.
    # root as a whole identifier in seg (not inside a longer name)
    function has_word(seg, root,    q, a, z, off) {
        off = 0
        while ((q = index(substr(seg, off + 1), root)) > 0) {
            q += off
            a = (q > 1) ? substr(seg, q - 1, 1) : " "
            z = substr(seg, q + length(root), 1)
            if (a !~ /[A-Za-z0-9_]/ && z !~ /[A-Za-z0-9_]/) return 1
            off = q
        }
        return 0
    }
    function raise_guarded(fn_text, root,    kw, k, t, p, seg) {
        split("STRICT_REQUIRE( ARG_GUARD BOOL_REFUSE( strict_numeric_byte_list( tensor_cells_numeric( gfx_list_all_num( FLAT_BAD( rt_error(EK_TYPE", kw, " ")
        for (k in kw) {
            t = fn_text
            while ((p = index(t, kw[k])) > 0) {
                seg = substr(t, p, 400)
                if (has_word(seg, root)) return 1
                t = substr(t, p + 1)
            }
        }
        return 0
    }
    function slot_guarded(fn_text, s) {
        if (index(fn_text, "slot_is_num(" s ")")) return 1
        if (index(fn_text, "slot_as_double(" s ",")) return 1
        if (index(fn_text, "slot_from_num(") && index(fn_text, s " = slot_from_num(")) return 1
        return 0
    }
    # A function starts at a column-0 line with a parameter list that is not a
    # declaration; its text accumulates until the column-0 closing brace.
    /^[A-Za-z_][^;#]*\(/ && $0 !~ /;[ \t]*$/ && $0 !~ /^(typedef|return|static const|extern)/ {
        fn = $0; sub(/\(.*/, "", fn); n = split(fn, w, /[ *]+/); fn = w[n]; text = ""
    }
    {
        line = $0
        # strip // comments and string literals (crudely) before scanning
        # block comments: drop a whole comment body, multi-line or not
        if (incmt) { if (index(line, "*/")) { line = substr(line, index(line, "*/") + 2); incmt = 0 } else line = "" }
        while (match(line, /\/\*([^*]|\*[^\/])*\*\//)) line = substr(line, 1, RSTART - 1) " " substr(line, RSTART + RLENGTH)
        if (index(line, "/*")) { line = substr(line, 1, index(line, "/*") - 1); incmt = 1 }
        sub(/\/\/.*/, "", line)
        gsub(/"([^"\\]|\\.)*"/, "\"\"", line)
        text = text "\n" line
        s = line
        off = 0
        while ((p = index(s, "data.num")) > 0) {
            abs = off + p
            rest = substr(s, p + 8)
            # write target: data.num = (not ==)
            if (rest ~ /^[ \t]*=[^=]/ ) { s = substr(s, p + 8); off = abs + 7; continue }
            pre = substr(line, 1, abs - 1)
            if (pre ~ /->$/) b = base_before(line, abs - 2)
            else if (pre ~ /\.$/) b = base_before(line, abs - 1)
            else { s = substr(s, p + 8); off = abs + 7; continue }
            v = guarded(text, b) ? "ok" : "bad"
            # Check-then-default: `X->type == VAL_NUM ? X->data.num : 0` (or
            # `if (X->type == VAL_NUM) d = X->data.num;`) is typed, but a bool
            # there silently means the default -- the #1637 round-2 class. It
            # needs a raising guard on X earlier in the function, or a
            # `soft:` allowlist entry.
            if (v == "ok" && line ~ /type == VAL_NUM/ && \
                (line ~ /VAL_NUM[^?]*[?]/ || line ~ /if *[(].*VAL_NUM.*[)] *[A-Za-z_*][A-Za-z0-9_>.*-]* *=[^=]/)) {
                root = b; sub(/[-[(].*/, "", root); sub(/^[(*]+/, "", root)
                if (!raise_guarded(text, root)) { v = "bad"; b = "soft:" b }
            }
            printf "%s|%s|%s|%d|%s\n", FILE, fn, b, NR, v
            s = substr(s, p + 8); off = abs + 7
        }
        s = line
        while (match(s, /[A-Za-z_][A-Za-z0-9_]*\.d([^A-Za-z0-9_]|$)/)) {
            tok = substr(s, RSTART, RLENGTH)
            nm = tok; sub(/\.d.*/, "", nm)
            after = substr(s, RSTART + RLENGTH - 1)
            prevc = (RSTART > 1) ? substr(s, RSTART - 1, 1) : ""
            if (prevc != ">" && prevc != "." && after !~ /^[ \t]*=[^=]/) {
                v = slot_guarded(text, nm) ? "ok" : "bad"
                printf "%s|%s|%s.d|%d|%s\n", FILE, fn, nm, NR, v
            }
            s = substr(s, RSTART + RLENGTH - 1)
        }
    }
    /^}/ { text = "" }
    ' "$f"
done > "$TMP"

examined=$(wc -l < "$TMP" | tr -d ' ')
allowlisted=0; violations=0; unused=0
used_keys=""
while IFS='|' read -r file fn opnd ln verdict; do
    [ "$verdict" = ok ] && continue
    key="$file|$fn|$opnd|"
    if grep -qF -- "$key" "$ALLOW"; then
        allowlisted=$((allowlisted + 1))
        used_keys="$used_keys
$key"
    else
        violations=$((violations + 1))
        case "$opnd" in
            soft:*) echo "  VIOLATION: src/$file:$ln $fn reads ${opnd#soft:} with a silent default for a non-number and no raising guard" ;;
            *)      echo "  VIOLATION: src/$file:$ln $fn reads $opnd as a number with no VAL_NUM check" ;;
        esac
    fi
done < "$TMP"
while IFS='|' read -r file fn opnd reason; do
    case "$file" in ''|\#*) continue ;; esac
    key="$file|$fn|$opnd|"
    if [ -z "$reason" ]; then echo "  FAIL: allowlist entry without a reason: $key"; unused=$((unused + 1)); continue; fi
    case "$used_keys" in *"
$key"*) ;; *) echo "  FAIL: unused allowlist entry: $key"; unused=$((unused + 1)) ;; esac
done < "$ALLOW"
echo "num-read: examined=$examined allowlisted=$allowlisted violations=$violations unused_allowlist=$unused"

# Class 2: every C-builtin call goes through eigs_call_builtin, the #1637 bool
# gate (a bare `X->data.builtin(arg)` call would skip it).
gated=$(cat "$SRC_DIR"/*.c | grep -c 'eigs_call_builtin(')
ungated=0
while IFS= read -r hit; do
    ungated=$((ungated + 1)); echo "  VIOLATION: ungated builtin call: $hit"
done < <(grep -n 'data\.builtin *(' "$SRC_DIR"/*.c | grep -v 'eigs_call_builtin(')
echo "bool-gate: call_sites=$gated ungated=$ungated"
[ "$gated" -gt 0 ] || { echo "bool-gate: FAIL (no gated call site found)"; violations=$((violations + 1)); }
violations=$((violations + ungated))
if [ "$examined" -le 0 ] || [ "$violations" -ne 0 ] || [ "$unused" -ne 0 ]; then
    echo "num-read: FAIL"; exit 1
fi
echo "num-read: PASS"
