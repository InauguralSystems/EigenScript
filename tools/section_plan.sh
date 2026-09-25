#!/bin/bash
# Derive whole-suite shards and audit section-level SKIP accounting (#1275).
# A shard is a set of complete top-level runner chunks. The matrix union,
# disjointness, and nonempty populations are checked before it runs.
# Usage: --chunks | --shards N --check | --shards N --shard K |
#        --shard-owner N [--section ID] | --emit-shard K N OUT |
#        --print-weights LOG [--run ID --head SHA] | --skip-audit | --selftest
set -u
SP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNNER="$SP_ROOT/tests/run_all_tests.sh"
VERBOSE=1
# A floor below today's 443 chunks catches a collapsed scan while allowing new sections.
CHUNK_FLOOR=400
# A floor below today's 24 emitters catches a vacuous audit while allowing additions.
SKIP_EMIT_FLOOR=20
# A floor below today's 24 routes catches a lost routing scan while allowing additions.
SKIP_ROUTED_FLOOR=20
CI_FILE="$SP_ROOT/.github/workflows/ci.yml"

#
# Match executable SKIP emitters; the helper owns section-level counts.
SKIP_EMIT_RE='^[[:space:]]*(echo|printf)[[:space:]].*SKIP'
SKIP_ROUTE_RE='^[[:space:]]*section_skip[[:space:]]'
# Content-pinned reasons for emitter lines that do not add a skipped section.
SKIP_WAIVERS='
6ef6a1325edf0172|(a) the section_skip helper own print — this IS the counter the audit polices
d8bbaacdbda76484|(b) the [99n] classifier-gate FAIL line, which QUOTES its own skipped tally; that section fails on any skip
e52b3a5c670b2434|(b) prose inside that same FAIL, explaining why a skipped check there is coverage loss
69614d3ef6dc2f30|(c) sub-check: [17] TR6/TR7 have no old model to reject; the rest of the transformer section still asserts
3f50de963077a3a2|(b) the [119] section TITLE, which names the sanitizer-only half in its own heading
86e12c645c5ad672|(c) sub-check: [119] Part B (the #548 borrow guard) is compiled out on a release build; Part A runs on every build and its PASS/FAIL lines are tallied
459741ca98fe2fc5|(b) the [44] HTTP-readiness FAIL line, which quotes skipped= in its verdict; two skips are the expected witnesses and any other count is already a FAIL there
23bf2806c94855bb|(b) a diagnostic inside that FAIL branch, printed only when the section is already red
4f08061db27787e7|(b) the [44-45/47] twin section LABEL; the skip beneath it is counted by section_skip
1a610a50ab85b616|(b) the [46/47] twin section LABEL; the skip beneath it is counted by section_skip
b9479b955a96ec10|(b) the [47/47] twin section LABEL; the skip beneath it is counted by section_skip
fab55a18d8a45227|(b) the [62] twin section LABEL; the skip beneath it is counted by section_skip
5ab04254fb943d66|(b) the [120b] twin section LABEL; the skip beneath it is counted by section_skip
8daea9a26364c262|(b) the [133] twin section LABEL; the skip beneath it is counted by section_skip
114496ab68d516e9|(b) the [134] twin section LABEL; the skip beneath it is counted by section_skip
512ecfac87c5101b|(b) the [132] twin section LABEL; the skip beneath it is counted by section_skip
2b1cec4b6df93886|(c) sub-check: [70d] relays the child rows verbatim, one of which SKIPs when GNU time -f is absent; the section still asserts its other two checks
cc548685179a777b|(c) sub-check: the JIT thunk gate on a non-x86_64 host; the JIT section asserts its fast-path checks on every host
00fd233b835a1ddb|(c) sub-check: the EIGS_JIT_HOT gate on a non-x86_64 host; same section, same reason
1d4789fa9df25921|(c) sub-check: --api --json validation needs python3; the --api section asserts its other rows without it
4fd0c1454b26ae7a|(b) an examples-section PASS line that reports how many demos were skipped for want of a gfx build
62be8333b50e395a|(b) the same PASS line on the no-gfx-build arm
27cfdaf9128456df|(b) the RESULTS line itself, which PRINTS the skipped count
43af9bdd1c5e1f94|(c) sub-check: [99zb] relays the portability tool own population/oracle line (widened by #1226 to include NO OLD BASH and other arm wordings); the section fails unless the tool reports OK or one of those named arms — supersedes the pre-#1226 row for this same relay
'
# One scratch root and one EXIT cleanup trap.
SP_TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/eigs_section_plan.XXXXXX") || {
    echo "section_plan: ERROR: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$SP_TMPROOT"' EXIT
sp_workdir() {   # <name> -> a fresh dir under the one root
    local d="$SP_TMPROOT/$1"
    rm -rf "$d"; mkdir -p "$d" || { echo "section_plan: ERROR: cannot create $d" >&2; exit 1; }
    printf '%s\n' "$d"
}

die() { echo "section_plan: ERROR: $*" >&2; exit 1; }
# Matrix size, ASAN_SHARDS, and every /N literal must agree.
SHARD_LITERAL_HOMES=3

shard_count_sync() {
    local ci="$1" n_env n_matrix n_lit n_name
    n_env=$(sed -n 's/^  ASAN_SHARDS: \([0-9][0-9]*\)$/\1/p' "$ci" | head -1)
    n_matrix=$(sed -n 's/^        shard: \[\(.*\)\]$/\1/p' "$ci" | head -1 | tr -cd ',' | wc -c)
    n_matrix=$((n_matrix + 1))
    # ONE RULE FOR ALL HOMES, rather than a row per known spelling: EVERY
    # `matrix.shard }}/<N>` in the file — job name, step name, env value, any
    # future one — must end in /$n_env. A per-spelling list is the thing that
    # missed the job name in the first place.
    #
    # ROUND 6: "all of them agree" is not enough on its own, because `>= 2`
    # let any ONE of the three be DELETED. Deleting the env-value one was the
    # dangerous case — `EIGS_SUITE_SHARD: ${{ matrix.shard }}` makes a job
    # still named "shard 1/3" run the WHOLE suite, with this check, the
    # aggregator and the receipts all still green. So the POPULATION is pinned
    # the way CAP_MARKER_FLOOR pins its own (a count that may only be changed
    # deliberately), and the load-bearing spelling — the env value the runner
    # actually parses — is required by name.
    n_lit=$(grep -coE 'matrix\.shard \}\}/[0-9]+' "$ci")
    n_bad=$(grep -oE 'matrix\.shard \}\}/[0-9]+' "$ci" | grep -vc "/$n_env\$")
    n_envval=$(grep -c "EIGS_SUITE_SHARD: \${{ matrix.shard }}/$n_env\$" "$ci")
    if [ -n "$n_env" ] && [ "$n_env" = "$n_matrix" ] \
       && [ "$n_lit" -eq "$SHARD_LITERAL_HOMES" ] && [ "$n_bad" -eq 0 ] && [ "$n_envval" -eq 1 ]; then
        echo "the ASan shard count agrees everywhere in ci.yml (ASAN_SHARDS=$n_env, matrix legs=$n_matrix, all $n_lit of $SHARD_LITERAL_HOMES 'matrix.shard }}/N' homes say /$n_env, EIGS_SUITE_SHARD among them)"
        return 0
    fi
    echo "ci.yml shard count disagrees (ASAN_SHARDS=${n_env:-unset}, matrix legs=$n_matrix, 'matrix.shard }}/N' occurrences=$n_lit of $SHARD_LITERAL_HOMES expected, $n_bad not saying /$n_env, EIGS_SUITE_SHARD:/$n_env present=$n_envval)"
    return 1
}
if command -v sha256sum >/dev/null 2>&1; then SP_HASHER="sha256sum"
elif command -v shasum >/dev/null 2>&1; then SP_HASHER="shasum -a 256"
else die "no sha256sum and no shasum on PATH — waivers cannot be content-pinned"; fi
sp_line_hash() { printf '%s' "$1" | $SP_HASHER | cut -c1-16; }
note() { [ "$VERBOSE" = "1" ] && echo "$*" >&2; return 0; }
# ---------------------------------------------------------------------------
# Ask bash -n for top-level boundaries, then emit chunk line ranges.
derive_chunks() {
    local f="$1"
    SP_TOTAL_LINES=$(wc -l < "$f" | tr -d ' ')

    # Epilogue anchor. Pinned and required to be UNIQUE: if it moves or is
    # duplicated the tool stops rather than guessing (a gate that guesses its
    # own boundary is the gate that silently measures less).
    local anchors
    anchors=$(grep -n '^# Final guard (#681)' "$f" | cut -d: -f1)
    local n_anchor
    n_anchor=$(printf '%s\n' "$anchors" | grep -c '[0-9]')
    [ "$n_anchor" = "1" ] || die "epilogue anchor '# Final guard (#681)' matched $n_anchor times in $f (need exactly 1)"
    SP_EPILOGUE_START="$anchors"

    # The prefix test is incremental, and that is a correctness argument, not
    # only a speed one: once PREV is known to be a top-level boundary, the file
    # up to L-1 parses iff the SEGMENT [PREV, L-1] parses on its own (a valid
    # prefix followed by a complete script is a valid prefix). Testing the
    # segment instead of the whole prefix turns 600 parses of a 7,000-line file
    # into 600 parses of ~15 lines.
    local cand boundaries="" L prev=""
    cand=$(grep -nE '^(echo "\[|# \[[0-9]|[A-Za-z_][A-Za-z0-9_]*_FILE=)' "$f" | cut -d: -f1)
    for L in $cand; do
        [ "$L" -lt "$SP_EPILOGUE_START" ] || continue
        [ "$L" -gt 1 ] || continue
        if [ -z "$prev" ]; then
            # First boundary only: the whole prefix has to be tested, because
            # there is no known-good anchor to measure a segment from.
            if head -n $((L - 1)) "$f" | bash -n 2>/dev/null; then
                boundaries="$L"; prev="$L"
            fi
            continue
        fi
        [ "$L" -gt "$prev" ] || continue
        if sed -n "${prev},$((L - 1))p" "$f" | bash -n 2>/dev/null; then
            boundaries="$boundaries $L"; prev="$L"
        fi
    done
    [ -n "$boundaries" ] || die "no top-level chunk boundary found in $f"

    # shellcheck disable=SC2086
    set -- $boundaries
    SP_PREAMBLE_END=$(( $1 - 1 ))

    local start end ids
    while [ "$#" -gt 0 ]; do
        start="$1"; shift
        if [ "$#" -gt 0 ]; then end=$(( $1 - 1 )); else end=$(( SP_EPILOGUE_START - 1 )); fi
        ids=$(sed -n "${start},${end}p" "$f" \
              | grep -oE 'echo "\[[^]]*\]' \
              | sed 's/^echo "//' \
              | tr '\n' ' ')
        printf '%s %s %s\n' "$start" "$end" "$ids"
    done
}

# Partition control: preamble + every chunk + epilogue must reconstruct the
# file byte-for-byte. Without it a boundary bug silently DROPS sections and
# every surviving assertion still passes.
verify_partition() {
    local f="$1" table="$2" tmp
    tmp=$(mktemp)
    [ "$SP_PREAMBLE_END" -ge 1 ] && sed -n "1,${SP_PREAMBLE_END}p" "$f" > "$tmp"
    local s e
    while read -r s e _rest; do
        [ -n "$s" ] || continue
        sed -n "${s},${e}p" "$f" >> "$tmp"
    done < "$table"
    sed -n "${SP_EPILOGUE_START},\$p" "$f" >> "$tmp"
    if ! cmp -s "$tmp" "$f"; then
        rm -f "$tmp"
        die "chunk table is not a partition of $f (preamble+chunks+epilogue != file)"
    fi
    rm -f "$tmp"
}

# Measured weights balance whole-runner chunks; missing labels use a reported
# default. The assignment is deterministic and checked as a disjoint union.
WEIGHTS_FILE_DEFAULT="tests/section_weights.txt"
SHARD_DEFAULT_CS=50          # centiseconds for an unmeasured section (0.5 s)

# chunk weights -> "<centiseconds> <chunk-start>" per line, plus the roster of
# section labels that had no measurement.
derive_chunk_weights() {
    local table="$1" out="$2" missing="$3"
    local wf="${WEIGHTS_FILE:-$WEIGHTS_FILE_DEFAULT}"
    # `: ;;` not `;;` — bash 3.2 cannot parse an empty inline arm (see
    # tools/docs_claims_check.sh and .claude/rules/test-suite.md). Pre-existing
    # here and never hit, because this tool runs on the linux lane only.
    case "$wf" in /*) : ;; *) wf="$SP_ROOT/$wf" ;; esac
    : > "$missing"
    if [ ! -f "$wf" ]; then
        SP_WEIGHTS_SOURCE="(none: $wf missing — every section takes the default)"
        awk -v def="$SHARD_DEFAULT_CS" '{ print def, $1 }' "$table" > "$out"
        awk '{ rest = $0; sub(/^[0-9]+[ \t]+[0-9]+[ \t]*/, "", rest)
               while (match(rest, /\[[^]]*\]/)) { print substr(rest, RSTART, RLENGTH); rest = substr(rest, RSTART + RLENGTH) } }' \
            "$table" | sort -u > "$missing"
    else
        SP_WEIGHTS_SOURCE="$wf"
        awk -v def="$SHARD_DEFAULT_CS" -v missfile="$missing" '
            FNR == NR {
                if ($0 ~ /^\[/) {
                    j = index($0, "]")
                    if (j > 0) { lbl = substr($0, 1, j); w[lbl] += int($NF * 100 + 0.5) }
                }
                next
            }
            {
                # The ids field is space-separated and a label may itself
                # contain spaces, so walk the bracketed tokens with a regex
                # rather than by field index.
                start = $1; total = 0; seen = ""
                rest = $0
                sub(/^[0-9]+[ \t]+[0-9]+[ \t]*/, "", rest)
                while (match(rest, /\[[^]]*\]/)) {
                    id = substr(rest, RSTART, RLENGTH)
                    rest = substr(rest, RSTART + RLENGTH)
                    if (index(seen, "|" id "|") > 0) continue
                    seen = seen "|" id "|"
                    if (id in w) total += w[id]
                    else { total += def; print id > missfile }
                }
                print total, start
            }
        ' "$wf" "$table" > "$out"
    fi
    sort -u "$missing" -o "$missing"
    SP_WEIGHT_MISSING=$(grep -c . "$missing")
}

# Merge chunks that share a cross-chunk variable dependency.
derive_chunk_groups() {
    local table="$1" out="$2"
    awk -v pre_end="$SP_PREAMBLE_END" '
        FNR == NR { n++; cs[n] = $1; ce[n] = $2; next }
        {
            line = FNR
            if (line <= pre_end) { scope = 0 }
            else {
                scope = 0
                while (cur < n && line > ce[cur]) cur++
                if (cur >= 1 && cur <= n && line >= cs[cur] && line <= ce[cur]) scope = cur
                else if (cur < n && line >= cs[cur + 1]) { cur++; if (line <= ce[cur]) scope = cur }
            }
            body = $0
            # ---- assignments, with the POSITION they happen at -------------
            # Round 5 (Astra): position matters. Round 4 recorded only
            # (name, chunk) and treated ANY same-chunk assignment as satisfying
            # EVERY read in that chunk — so a read that PRECEDES a later
            # same-chunk reassignment lost its producer in an earlier chunk,
            # the chunks were not merged, and the consumer shard printed an
            # empty value and exited 0. Assignments and reads now carry
            # (line, column) and a read is satisfied only by an assignment
            # EARLIER IN PROGRAM ORDER.
            if (match(body, /^[ \t]*[A-Za-z_][A-Za-z0-9_]*=/)) {
                nm = substr(body, RSTART, RLENGTH - 1); gsub(/^[ \t]+/, "", nm)
                if (scope == 0) pre[nm] = 1
                else record_asg(nm, scope, line, RSTART)
            }
            # Mid-line assignments (`cmd; NAME=v`, `a && NAME=v`) — the dual of
            # the same bug: a producer the scanner cannot see is a merge it
            # cannot make.
            rest2 = body; off2 = 0
            while (match(rest2, /[;&|(][ \t]*[A-Za-z_][A-Za-z0-9_]*=/)) {
                t = substr(rest2, RSTART, RLENGTH); col = off2 + RSTART
                off2 += RSTART + RLENGTH - 1
                rest2 = substr(rest2, RSTART + RLENGTH)
                sub(/^[;&|(][ \t]*/, "", t); sub(/=$/, "", t)
                if (scope == 0) pre[t] = 1; else record_asg(t, scope, line, col)
            }
            if (match(body, /^[ \t]*(local|export|declare)[ \t]+[A-Za-z_][A-Za-z0-9_]*/)) {
                t = substr(body, RSTART, RLENGTH); sub(/^[ \t]*(local|export|declare)[ \t]+/, "", t)
                if (scope == 0) pre[t] = 1; else record_asg(t, scope, line, RSTART)
            }
            if (match(body, /for[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]+in/)) {
                t = substr(body, RSTART, RLENGTH); sub(/^for[ \t]+/, "", t); sub(/[ \t]+in$/, "", t)
                if (scope == 0) pre[t] = 1; else record_asg(t, scope, line, RSTART)
            }
            # ---- reads, with their position --------------------------------
            if (scope > 0) {
                rest = body; off = 0
                while (match(rest, /\$\{?[A-Za-z_][A-Za-z0-9_]*/)) {
                    v = substr(rest, RSTART, RLENGTH); col = off + RSTART
                    off += RSTART + RLENGTH - 1
                    rest = substr(rest, RSTART + RLENGTH)
                    gsub(/[$\{]/, "", v)
                    nr++; rv[nr] = v; rc[nr] = scope; rl[nr] = line; rk[nr] = col
                }
            }
        }
        END {
            for (i = 1; i <= n; i++) parent[i] = i
            for (j = 1; j <= nr; j++) {
                v = rv[j]; c = rc[j] + 0
                if (v in pre) continue
                if (!(v in names)) continue
                if (satisfied_before(v, c, rl[j], rk[j])) continue
                best = 0
                for (i = 1; i < c; i++) if ((v SUBSEP i) in A) best = i
                if (best == 0) continue
                ra = find(c); rb = find(best)
                if (ra != rb) {
                    if (ra < rb) parent[rb] = ra; else parent[ra] = rb
                    merges++
                    printf "MERGE %s %d %d\n", v, cs[best], cs[c] > "/dev/stderr"
                }
            }
            for (i = 1; i <= n; i++) printf "%d %d\n", cs[i], cs[find(i)]
            printf "MERGES %d\n", merges + 0 > "/dev/stderr"
        }
        # Only the EARLIEST assignment of a name in a chunk can matter: if that
        # one is not before the read, none is. Keeping just the minimum keeps
        # the lookup O(1) — scanning every assignment per read was O(reads x
        # assignments) and took the selftest from minutes to over ten.
        function record_asg(nm, sc, ln, col,   k) {
            na++
            k = nm SUBSEP sc
            if (!(k in A) || ln < minl[k] || (ln == minl[k] && col < minc[k])) {
                minl[k] = ln; minc[k] = col
            }
            A[k] = 1; names[nm] = 1
        }
        # A same-chunk assignment counts only if it happens BEFORE the read in
        # program order: an earlier line, or the same line at an earlier column.
        function satisfied_before(v, c, ln, col,   k) {
            k = v SUBSEP c
            if (!(k in A)) return 0
            if (minl[k] < ln) return 1
            if (minl[k] == ln && minc[k] < col) return 1
            return 0
        }
        function find(x) { while (parent[x] != x) { parent[x] = parent[parent[x]]; x = parent[x] } return x }
    ' "$table" "$RUNNER" > "$out" 2> "$out.merges"
    SP_GROUP_MERGES=$(sed -n 's/^MERGES \([0-9]*\)$/\1/p' "$out.merges")
    : "${SP_GROUP_MERGES:=0}"
    SP_GROUP_MERGE_LIST=$(sed -n 's/^MERGE /  merged: /p' "$out.merges")
    SP_GROUPS=$(cut -d' ' -f2 "$out" | sort -u | grep -c .)
}


# Deterministic longest-processing-time greedy. Emits "<chunk-start> <shard>".
derive_shard_assignment() {
    local n="$1" weights="$2" out="$3" groups="${4:-}"
    if [ -n "$groups" ]; then
        # Aggregate each group's weight onto its leader, split the LEADERS, then
        # expand back: a group is indivisible, so the balance is over groups.
        local W2="$SP_TMPROOT/grp"
        mkdir -p "$W2"
        awk 'FNR == NR { g[$1] = $2; next } { lead = ($2 in g) ? g[$2] : $2; t[lead] += $1 }
             END { for (k in t) print t[k], k }' "$groups" "$weights" > "$W2/gw"
        sort -k1,1nr -k2,2n "$W2/gw" \
          | awk -v n="$n" '
                BEGIN { for (i = 1; i <= n; i++) { load[i] = 0; cnt[i] = 0 } }
                {
                    best = 1
                    for (i = 2; i <= n; i++)
                        if (load[i] < load[best] || (load[i] == load[best] && cnt[i] < cnt[best])) best = i
                    load[best] += $1; cnt[best]++
                    print $2, best
                }
            ' > "$W2/ga"
        awk 'FNR == NR { sh[$1] = $2; next } { print $1, sh[$2] }' "$W2/ga" "$groups" | sort -n > "$out"
        return 0
    fi
    sort -k1,1nr -k2,2n "$weights" \
      | awk -v n="$n" '
            BEGIN { for (i = 1; i <= n; i++) { load[i] = 0; cnt[i] = 0 } }
            {
                # Ties break on chunk COUNT, then on index, so a table of equal
                # weights round-robins instead of piling every chunk into
                # bucket 1 (which is what an unmeasured tree does).
                best = 1
                for (i = 2; i <= n; i++)
                    if (load[i] < load[best] || (load[i] == load[best] && cnt[i] < cnt[best])) best = i
                load[best] += $1; cnt[best]++
                print $2, best
            }
        ' | sort -n > "$out"
}

shard_loads() {   # "<shard> <chunks> <seconds>" per shard
    local weights="$1" assign="$2" n="$3"
    awk -v n="$n" '
        FNR == NR { w[$2] = $1; next }
        { c[$2]++; t[$2] += w[$1] }
        END { for (i = 1; i <= n; i++) printf "%d %d %d.%02d\n", i, c[i] + 0, t[i] / 100, t[i] % 100 }
    ' "$weights" "$assign"
}

# The pin: union == the full chunk list, and pairwise disjoint. Both directions
# (mechanical-gates §2) — "every chunk is in a shard" and "no chunk is in two"
# fail differently, and only the second catches a duplicated chunk.
shard_check() {
    local n="$1"
    validate_shards "$n"
    local W; W=$(sp_workdir shards)
    derive_chunks "$RUNNER" > "$W/chunks"
    verify_partition "$RUNNER" "$W/chunks"
    check_chunk_count "$W/chunks"
    shard_count_sync "$CI_FILE" || die "ASan shard count is not synchronized"
    derive_chunk_weights "$W/chunks" "$W/weights" "$W/missing"
    derive_chunk_groups "$W/chunks" "$W/groups"
    derive_shard_assignment "$n" "$W/weights" "$W/assign" "$W/groups"

    # TEST-ONLY mutation seam, used by --selftest to prove this check fires.
    # It can only REMOVE or DUPLICATE an assignment — never add coverage — so
    # the worst it can do is turn the check red, and it announces itself.
    case "${SP_SHARD_MUTATE:-}" in
        drop) echo "section_plan: WARNING: SP_SHARD_MUTATE=drop — one chunk removed from every shard (selftest seam)" >&2
              sed -i '1d' "$W/assign" ;;
        dup)  echo "section_plan: WARNING: SP_SHARD_MUTATE=dup — one chunk placed in two shards (selftest seam)" >&2
              head -1 "$W/assign" | awk -v n="$n" '{ print $1, ($2 % n) + 1 }' >> "$W/assign"
              sort -n -o "$W/assign" "$W/assign" ;;
    esac

    local total assigned uniq
    total=$(grep -c '[0-9]' "$W/chunks")
    assigned=$(grep -c '[0-9]' "$W/assign")
    cut -d' ' -f1 "$W/assign" | sort -n -u > "$W/assigned_uniq"
    uniq=$(grep -c '[0-9]' "$W/assigned_uniq")
    cut -d' ' -f1 "$W/chunks" | sort -n > "$W/all_chunks"

    [ "$assigned" = "$uniq" ] || die "shards OVERLAP: $assigned assignments over $uniq distinct chunks — a chunk in two shards is counted twice and its failures are reported twice"
    if ! cmp -s "$W/all_chunks" "$W/assigned_uniq"; then
        echo "section_plan: ERROR: the shard union is not the full chunk list:" >&2
        diff "$W/all_chunks" "$W/assigned_uniq" | head -20 >&2
        die "union != full — a chunk in no shard is a section that silently left CI"
    fi
    [ "$total" -gt 0 ] || die "chunk enumeration examined=0 floor=$CHUNK_FLOOR (scan is vacuous)"
    # More shards than chunks cannot produce N non-empty shards, and the
    # per-shard loop below would report the shortfall one shard at a time.
    [ "$n" -le "$total" ] || die "asked for $n shards over $total chunks — at least one shard would be empty"

    local i cnt examined=0
    for i in $(seq 1 "$n"); do
        examined=$((examined + 1))
        cnt=$(awk -v k="$i" '$2 == k' "$W/assign" | grep -c .)
        [ "$cnt" -gt 0 ] || die "shard $i/$n got ZERO chunks — a job that measures nothing must not be green"
    done
    [ "$examined" -eq "$n" ] && [ "$examined" -gt 0 ] || die "shard enumeration examined=$examined expected=$n"

    if [ "$VERBOSE" = "1" ]; then
        echo "weights: $SP_WEIGHTS_SOURCE"
        if [ "$SP_WEIGHT_MISSING" -gt 0 ]; then
            echo "UNMEASURED sections (default ${SHARD_DEFAULT_CS}cs each) — refresh the weights table:"
            sed 's/^/  /' "$W/missing"
        fi
        if [ -n "$SP_GROUP_MERGE_LIST" ]; then
            echo "chunk groups merged for a cross-chunk variable dependency:"
            printf '%s\n' "$SP_GROUP_MERGE_LIST"
        fi
        shard_loads "$W/weights" "$W/assign" "$n" \
          | while read -r k c t; do echo "  shard $k/$n: chunks=$c weight=${t}s"; done
    fi
    echo "SHARDS: n=$n chunks=$total groups=$SP_GROUPS (merges=$SP_GROUP_MERGES) union=full disjoint=yes zero-section-shards=0 unmeasured-sections=$SP_WEIGHT_MISSING"
}

# Extras go to the lightest shard or the shard carrying a named section.
shard_owner() {
    local n="$1" section="${2:-}"
    validate_shards "$n"
    SP_WORK="${SP_WORK:-$(sp_workdir owner)}"
    derive_chunks "$RUNNER" > "$SP_WORK/chunks"
    check_chunk_count "$SP_WORK/chunks"
    derive_chunk_weights "$SP_WORK/chunks" "$SP_WORK/weights" "$SP_WORK/missing"
    derive_chunk_groups "$SP_WORK/chunks" "$SP_WORK/groups"
    derive_shard_assignment "$n" "$SP_WORK/weights" "$SP_WORK/assign" "$SP_WORK/groups"

    if [ -n "$section" ]; then
        local start owner
        start=$(awk -v id="$section" '{ for (i = 3; i <= NF; i++) if ($i == id) { print $1; exit } }' "$SP_WORK/chunks")
        [ -n "$start" ] || die "no chunk carries section '$section' — the extra it owns has no home"
        owner=$(awk -v s="$start" '$1 == s { print $2 }' "$SP_WORK/assign")
        [ -n "$owner" ] || die "section '$section' is in chunk @$start, which no shard claimed"
        echo "$owner"
        return 0
    fi
    shard_loads "$SP_WORK/weights" "$SP_WORK/assign" "$n" \
      | sort -k3,3g -k1,1n | head -1 | cut -d' ' -f1
}

print_weights() {
    local log="$1"
    [ -f "$log" ] || die "no such log: $log"
    # A raw CI job log (`gh api .../jobs/<id>/logs`) prefixes every line with an
    # ISO timestamp, so the pattern tolerates one rather than making the caller
    # strip it by hand — a manual pre-step is a step someone does differently.
    # The floor is the RUNNER'S OWN label population, not a magic 50. A single
    # shard log has ~78 rows and sailed through the old floor, which would have
    # produced a table with ~160 sections silently taking the default weight —
    # and a default-weighted section is exactly what the table exists to stop.
    # The input for a sharded lane is the shard logs CONCATENATED.
    local n distinct want
    n=$(grep -cE '^([0-9-]+T[0-9:.]+Z )?SECTION_TIME: ' "$log")
    distinct=$(grep -oE 'SECTION_TIME: \[[^]]*\]' "$log" | sort -u | grep -c .)
    want=$(grep -oE 'echo "\[[^]]*\]' "$RUNNER" | sort -u | grep -c .)
    # 85%, not 100%: one binary prints only one side of extension branches
    # (the asan-http build never prints the HTTP/model skip headings), so
    # requiring every label would refuse a complete set of real logs.
    want=$(( want * 85 / 100 ))
    [ "$n" -ge 50 ] || die "only $n SECTION_TIME lines in $log — that log is not a suite run at all"
    [ "$distinct" -ge "$want" ] || die "only $distinct distinct sections in $log, need >= $want (85% of the $(grep -oE 'echo "\[[^]]*\]' "$RUNNER" | sort -u | grep -c .) labels in the runner) — this looks like ONE shard's log; concatenate every shard's log, or the table would default the sections it cannot see"
    # PROVENANCE COMES FROM THE ARGS, so the documented recipe reproduces the
    # committed file byte-for-byte (#1160 round 6). Round 5 hand-wrote a
    # 14-line header that the very recipe printed next to it would have ERASED
    # — a regeneration step that silently drops the answer to "where did these
    # numbers come from" is how a table becomes unverifiable.
    local rows
    rows=$(grep -oE 'SECTION_TIME: \[[^]]*\]' "$log" | sort -u | grep -c .)
    echo "# tests/section_weights.txt — per-section wall seconds, summed per label."
    echo "#"
    if [ -n "${WEIGHTS_RUN:-}" ] || [ -n "${WEIGHTS_HEAD:-}" ]; then
        echo "# MEASURED ON THE CI RUNNER, not on the dev box: run ${WEIGHTS_RUN:-unstated},"
        echo "# head ${WEIGHTS_HEAD:-unstated}, the \`asan + ubsan / shard k/N (http+model build)\`"
        echo "# job logs, concatenated and fed to \`--print-weights\`."
    else
        echo "# PROVENANCE NOT STATED: this table was generated without --run/--head."
        echo "# Measure on the CI RUNNER and pass them, or the numbers cannot be traced."
    fi
    echo "# $n SECTION_TIME lines, $rows distinct sections."
    echo "#"
    echo "# Refresh from every shard log of the same CI run. Different binary"
    echo "# builds and runner hosts have different section costs."
    echo "#"
    echo "# Refresh — see docs/CI.md for the gh api recipe:"
    echo "#   tools/section_plan.sh --print-weights <ci-shard-logs> \\"
    echo "#       --run ${WEIGHTS_RUN:-<run id>} --head ${WEIGHTS_HEAD:-<head sha>} > tests/section_weights.txt"
    # A section label may contain spaces ("[JSON Depth / DoS guard]"), so the
    # label is everything from the first [ to the first ] and the seconds are
    # the LAST field — splitting on whitespace produced rows like "[Structural"
    # and a weights table with 21 phantom entries.
    awk '/^([0-9-]+T[0-9:.]+Z )?SECTION_TIME: / {
             i = index($0, "["); j = index($0, "]")
             if (i == 0 || j <= i) next
             lbl = substr($0, i, j - i + 1)
             cs[lbl] += int($NF * 100 + 0.5)
         }
         END { for (k in cs) printf "%s %d.%02d\n", k, cs[k] / 100, cs[k] % 100 }' "$log" | sort
}

skip_audit() {
    local f="$1" work="$2"
    local hits="$work/skip_hits" unacct="$work/skip_unaccounted" used="$work/skip_waivers_used"
    : > "$hits"; : > "$unacct"; : > "$used"

    grep -nE "$SKIP_EMIT_RE" "$f" >> "$hits"
    SP_SKIP_EMITS=$(grep -c . "$hits")
    [ "$SKIP_EMIT_FLOOR" -gt 0 ] && [ "$SP_SKIP_EMITS" -ge "$SKIP_EMIT_FLOOR" ] || \
        die "skip emitter enumeration examined=$SP_SKIP_EMITS floor=$SKIP_EMIT_FLOOR (scan is vacuous below floor)"

    SP_SKIP_ROUTED=$(grep -cE "$SKIP_ROUTE_RE" "$f")
    [ "$SKIP_ROUTED_FLOOR" -gt 0 ] && [ "$SP_SKIP_ROUTED" -ge "$SKIP_ROUTED_FLOOR" ] || \
        die "skip route enumeration examined=$SP_SKIP_ROUTED floor=$SKIP_ROUTED_FLOOR (scan is vacuous below floor)"

    local hit lineno text thash whash wreason ok
    while IFS= read -r hit; do
        [ -n "$hit" ] || continue
        lineno=${hit%%:*}; text=${hit#*:}
        thash=$(sp_line_hash "$text")
        ok=""
        while IFS='|' read -r whash wreason; do
            [ -n "${whash:-}" ] || continue
            if [ "$whash" = "$thash" ]; then
                ok="waiver"; printf '%s\n' "$whash" >> "$used"; break
            fi
        done <<EOF
$SKIP_WAIVERS
EOF
        [ -n "$ok" ] || printf '%s:%s\n' "$lineno" "$text" >> "$unacct"
    done < "$hits"

    if [ -s "$unacct" ] && [ "${SP_PRINT_WAIVERS:-0}" = "1" ]; then
        echo "# Paste-ready SKIP_WAIVERS rows for the UNACCOUNTED lines below."
        echo "# Each needs a REASON written by a reviewer; a bare hash is not a waiver."
        while IFS= read -r hit; do
            [ -n "$hit" ] || continue
            lineno=${hit%%:*}; text=${hit#*:}
            printf '%s|REASON HERE — line %s: %.70s\n' "$(sp_line_hash "$text")" "$lineno" "$text"
        done < "$unacct"
        die "$(grep -c . "$unacct") unaccounted SKIP line(s); rows printed above, nothing was written"
    fi
    if [ -s "$unacct" ]; then
        echo "section_plan: ERROR: SKIP-emitting line(s) in $f that neither go through section_skip() nor carry a reviewed reason:" >&2
        sed 's/^/    /' "$unacct" >&2
        die "a section whose verdict is a skip must call section_skip (it prints AND counts, so the RESULTS line's 'N skipped' is true); a sub-check skip must be listed in SKIP_WAIVERS with the section that still measures"
    fi

    local unused=""
    while IFS='|' read -r whash wreason; do
        [ -n "${whash:-}" ] || continue
        grep -qxF "$whash" "$used" || unused="$unused
    $whash|$wreason"
    done <<EOF
$SKIP_WAIVERS
EOF
    if [ -n "$unused" ]; then
        echo "section_plan: ERROR: SKIP_WAIVERS entries that matched nothing:$unused" >&2
        die "an unused skip waiver means the line it described changed shape — re-read it and decide again whether that skip is section-level (route it) or a sub-check (re-pin it)"
    fi
    SP_SKIP_WAIVERS_USED=$(sort -u "$used" | grep -c .)
}

# ---------------------------------------------------------------------------
# Reject empty and malformed shard populations before enumeration.
validate_shards() {
    local n="$1"
    case "$n" in
        ''|*[!0-9]*) die "shard count must be a positive integer, got '$n'" ;;
    esac
    [ "$n" -ge 1 ] || die "shard count must be >= 1, got '$n'"
}

# The runner text is the count oracle. A selected chunk can contain alternate
# headings for a compiled extension; inspect the last-built binary's hard link
# and its Makefile flags before the shard starts. No runner output enters this
# count. An unrecognised binary takes the present arm, so a synthetic runner's
# conditional headings remain promised even when a fault hides them at runtime.
shard_build_features() {
    SP_MODEL=1 SP_HTTP=1 SP_DB=1 SP_NET=1 SP_GFX=1 SP_ZLIB=1
    local binary="$SP_ROOT/src/eigenscript" built variant flags
    [ -e "$binary" ] || return 0
    [ -f "$SP_ROOT/Makefile" ] || return 0
    for built in "$SP_ROOT"/build/*/eigenscript; do
        [ -e "$built" ] && [ "$binary" -ef "$built" ] || continue
        variant=${built%/eigenscript}; variant=${variant##*/}
        flags=$(sed -n "s/^FLAGS_${variant} := //p" "$SP_ROOT/Makefile")
        [ -n "$flags" ] || die "no Makefile flags for built variant $variant"
        SP_NET=0 SP_GFX=0 SP_ZLIB=0
        case "$flags" in *'$(DEFS_OFF)'*) SP_MODEL=0 SP_HTTP=0 SP_DB=0 ;; esac
        case "$flags" in *'-DEIGENSCRIPT_EXT_MODEL=0'*) SP_MODEL=0 ;; *'-DEIGENSCRIPT_EXT_MODEL=1'*) SP_MODEL=1 ;; esac
        case "$flags" in *'-DEIGENSCRIPT_EXT_HTTP=0'*) SP_HTTP=0 ;; *'-DEIGENSCRIPT_EXT_HTTP=1'*) SP_HTTP=1 ;; esac
        case "$flags" in *'-DEIGENSCRIPT_EXT_DB=0'*) SP_DB=0 ;; *'-DEIGENSCRIPT_EXT_DB=1'*) SP_DB=1 ;; esac
        case "$flags" in *'-DEIGENSCRIPT_EXT_NET=1'*) SP_NET=1 ;; esac
        case "$flags" in *'-DEIGENSCRIPT_EXT_GFX=1'*) SP_GFX=1 ;; esac
        case "$flags" in *'-DEIGENSCRIPT_EXT_ZLIB=1'*) SP_ZLIB=1 ;; esac
        return 0
    done
}

# Count literal heading calls in selected source ranges. The branch twins are
# mutually exclusive; an absent extension can also have no alternate heading.
chunk_executed_headers() {
    local s="$1" e="$2" body top cond feature=1 present absent
    body=$(sed -n "${s},${e}p" "$RUNNER")
    top=$(printf '%s\n' "$body" | grep -cE '^echo "\[[^]]*\]')
    present=$(printf '%s\n' "$body" | grep -E '^[[:space:]]+echo "\[[^]]*\]' | grep -vcE 'SKIPPED \(|skipped — |stub check')
    absent=$(printf '%s\n' "$body" | grep -E '^[[:space:]]+echo "\[[^]]*\]' | grep -cE 'SKIPPED \(|skipped — |stub check')
    case "$body" in
        *'binary built without EIGENSCRIPT_EXT_HTTP'*) feature=$SP_HTTP ;;
        *'binary built without EIGENSCRIPT_EXT_DB'*) feature=$SP_DB ;;
        *'binary built without EIGENSCRIPT_EXT_MODEL'*) feature=$SP_MODEL ;;
        *'binary built without EIGENSCRIPT_EXT_GFX'*) feature=$SP_GFX ;;
        *'minimal build, stub check'*) feature=$SP_ZLIB ;;
        *'gfx demos skipped'*) feature=$SP_GFX ;;
        *'eigen_model_loaded of null'*) feature=$SP_MODEL ;;
        *'print of net_close'*) feature=$SP_NET ;;
    esac
    if [ "$feature" -eq 1 ]; then cond=$present; else cond=$absent; fi
    echo $((top + cond))
}

# One emitted shard runs selected chunks. The parent compares its static PLAN
# count with section headers printed on the run's own stdout.
build_shard_plan() {
    local k="$1" n="$2" s
    validate_shards "$n"; validate_shards "$k"
    [ "$k" -le "$n" ] || die "shard index $k is outside 1..$n"
    SP_WORK=$(sp_workdir plan)
    derive_chunks "$RUNNER" > "$SP_WORK/chunks"
    verify_partition "$RUNNER" "$SP_WORK/chunks"
    check_chunk_count "$SP_WORK/chunks"
    derive_chunk_weights "$SP_WORK/chunks" "$SP_WORK/weights" "$SP_WORK/missing"
    derive_chunk_groups "$SP_WORK/chunks" "$SP_WORK/groups"
    derive_shard_assignment "$n" "$SP_WORK/weights" "$SP_WORK/assign" "$SP_WORK/groups"
    awk -v k="$k" '$2 == k { print $1 }' "$SP_WORK/assign" | sort -n > "$SP_WORK/selected"
    SP_SEL_CHUNKS=$(grep -c '[0-9]' "$SP_WORK/selected")
    [ "$SP_SEL_CHUNKS" -gt 0 ] || die "shard $k/$n selected ZERO chunks"
    shard_build_features
    local e nsec
    SP_SEL_SECTIONS=0
    while read -r s; do
        [ -n "$s" ] || continue
        e=$(awk -v ss="$s" '$1 == ss { print $2 }' "$SP_WORK/chunks")
        nsec=$(chunk_executed_headers "$s" "$e")
        SP_SEL_SECTIONS=$((SP_SEL_SECTIONS + nsec))
    done < "$SP_WORK/selected"
    [ "$SP_SEL_SECTIONS" -gt 0 ] || die "shard $k/$n selected ZERO section headers"
    local wsec
    wsec=$(shard_loads "$SP_WORK/weights" "$SP_WORK/assign" "$n" | awk -v k="$k" '$1 == k {print $3}')
    note "shard=$k/$n weights=$SP_WEIGHTS_SOURCE unmeasured=$SP_WEIGHT_MISSING"
    echo "PLAN: shard=$k/$n sections=$SP_SEL_SECTIONS chunks=$SP_SEL_CHUNKS predicted=${wsec}s unmeasured=$SP_WEIGHT_MISSING"
}

check_chunk_count() {
    local examined
    examined=$(grep -c '[0-9]' "$1")
    [ "$CHUNK_FLOOR" -gt 0 ] && [ "$examined" -ge "$CHUNK_FLOOR" ] ||
        die "chunk enumeration examined=$examined floor=$CHUNK_FLOOR (scan is vacuous below floor)"
}

emit_shard() {
    local k="$1" n="$2" out="$3" planline
    build_shard_plan "$k" "$n" > "$SP_TMPROOT/plan.line"
    planline=$(cat "$SP_TMPROOT/plan.line")
    {
        echo '#!/bin/bash'
        echo "# GENERATED by tools/section_plan.sh; $planline"
        echo 'EIGS_PLAN_ACTIVE=1; export EIGS_PLAN_ACTIVE'
        printf "EIGS_PLAN_TESTS_DIR='%s/tests'; export EIGS_PLAN_TESTS_DIR\n" "$SP_ROOT"
        echo 'EIGS_SECTION_TIME=1; export EIGS_SECTION_TIME'
        sed -n "1,${SP_PREAMBLE_END}p" "$RUNNER"
        local s e
        while read -r s; do
            [ -n "$s" ] || continue
            e=$(awk -v ss="$s" '$1==ss {print $2}' "$SP_WORK/chunks")
            sed -n "${s},${e}p" "$RUNNER"
        done < "$SP_WORK/selected"
        sed -n "${SP_EPILOGUE_START},\$p" "$RUNNER"
    } > "$out"
    bash -n "$out" || die "emitted runner is not syntactically valid: $out"
    echo "$planline"
}
# Calibration: every planted fault invokes the public arm it must turn red.
selftest() {
    local dir out pass=0 fail=0 rc label want
    dir=$(sp_workdir selftest)
    expect_ok() {
        label="$1"; shift
        if out=$("$@" 2>&1); then
            echo "  PASS: $label"; pass=$((pass + 1))
        else
            rc=$?; echo "  FAIL: $label (rc=$rc)"; printf '%s\n' "$out" | tail -8; fail=$((fail + 1))
        fi
    }
    expect_red() {
        label="$1" want="$2"; shift 2
        if out=$("$@" 2>&1); then
            echo "  FAIL: $label (plant survived)"; fail=$((fail + 1))
        else
            case "$out" in
                *"$want"*) echo "  PASS: $label"; pass=$((pass + 1)) ;;
                *) echo "  FAIL: $label (wrong red)"; printf '%s\n' "$out" | tail -8; fail=$((fail + 1)) ;;
            esac
        fi
    }
    echo 'section_plan selftest: copied plants, public modes'
    expect_ok 'control: chunk derivation and byte-exact partition' "$0" --root "$SP_ROOT" --chunks --quiet
    cp "$RUNNER" "$dir/no_anchor.sh"
    sed 's/^# Final guard (#681)/# Final guard/' "$dir/no_anchor.sh" > "$dir/t"; mv "$dir/t" "$dir/no_anchor.sh"
    expect_red 'derive_chunks: missing epilogue anchor' 'epilogue anchor' "$0" --root "$SP_ROOT" --chunks --runner "$dir/no_anchor.sh" --quiet
    sed 's/^CHUNK_FLOOR=400$/CHUNK_FLOOR=999999/' "$0" > "$dir/bad-count.sh"
    chmod +x "$dir/bad-count.sh"
    expect_red 'check_chunk_count: vacuous chunk population falls below floor' 'chunk enumeration examined' \
        "$dir/bad-count.sh" --root "$SP_ROOT" --chunks --quiet
    expect_ok 'control: complete, disjoint shard assignment and count sync' "$0" --root "$SP_ROOT" --shards 3 --check --quiet
    expect_red 'shard_check: missing chunk makes union != full' 'union != full' \
        env SP_SHARD_MUTATE=drop "$0" --root "$SP_ROOT" --shards 3 --check --quiet
    expect_red 'shard_check: duplicate chunk makes shards OVERLAP' 'shards OVERLAP' \
        env SP_SHARD_MUTATE=dup "$0" --root "$SP_ROOT" --shards 3 --check --quiet
    sed 's/^  ASAN_SHARDS: 3$/  ASAN_SHARDS: 4/' "$CI_FILE" > "$dir/bad-ci.yml"
    expect_red 'shard_count_sync: changed ASAN_SHARDS disagrees with matrix and /N' 'shard count disagrees' \
        "$0" --root "$SP_ROOT" --ci-file "$dir/bad-ci.yml" --shards 3 --check --quiet
    expect_ok 'control: skip audit examines emitters and routes above floors' "$0" --root "$SP_ROOT" --skip-audit
    cp "$RUNNER" "$dir/bad-skip.sh"
    echo 'echo "  SKIP: planted bare emitter"' >> "$dir/bad-skip.sh"
    expect_red 'skip_audit: new bare SKIP emitter is unaccounted' 'SKIP-emitting line' \
        "$0" --root "$SP_ROOT" --runner "$dir/bad-skip.sh" --skip-audit
    sed 's/^SKIP_EMIT_FLOOR=20$/SKIP_EMIT_FLOOR=999999/' "$0" > "$dir/bad-skip-count.sh"
    chmod +x "$dir/bad-skip-count.sh"
    expect_red 'skip_audit: vacuous emitter scan falls below floor' 'skip emitter enumeration' \
        "$dir/bad-skip-count.sh" --root "$SP_ROOT" --skip-audit
    sed -E '/^[[:space:]]*section_skip[[:space:]]/ s/section_skip/section_skiP/' "$RUNNER" > "$dir/bad-route.sh"
    expect_red 'skip_audit: vacuous route scan falls below floor' 'skip route enumeration' \
        "$0" --root "$SP_ROOT" --runner "$dir/bad-route.sh" --skip-audit
    expect_ok 'control: lightest shard has one owner' "$0" --root "$SP_ROOT" --shard-owner 3 --quiet
    expect_ok 'control: [88] has one shard owner' "$0" --root "$SP_ROOT" --shard-owner 3 --section '[88]' --quiet
    expect_red 'shard_owner: nonexistent section has no owner' 'no chunk carries section' \
        "$0" --root "$SP_ROOT" --shard-owner 3 --section '[absent]' --quiet
    expect_ok 'control: emit shard passes bash syntax check' "$0" --root "$SP_ROOT" --emit-shard 2 3 "$dir/shard.sh" --quiet
    [ -s "$dir/shard.sh" ] && bash -n "$dir/shard.sh" || { echo '  FAIL: emitted shard absent or invalid'; fail=$((fail + 1)); }
    # Inert runner with the real dispatch/timer preamble. Its source promises
    # every heading; the planted runtime condition hides all but three.
    local stub="$dir/stub" i
    mkdir -p "$stub/tests" "$stub/tools" "$stub/src" "$stub/.github/workflows"
    cp "$SP_ROOT/tools/section_plan.sh" "$SP_ROOT/tools/read_werror_flags.sh" \
       "$SP_ROOT/tools/werror_flags.txt" "$stub/tools/"
    cp "$SP_ROOT/tests/failure_output.sh" "$SP_ROOT/tests/section_weights.txt" "$stub/tests/"
    cp "$CI_FILE" "$stub/.github/workflows/ci.yml"
    printf '#!/bin/sh\nexit 0\n' > "$stub/src/eigenscript"
    chmod +x "$stub/src/eigenscript"
    awk '/^PASS=0$/{exit} {print}' "$RUNNER" > "$stub/tests/run_all_tests.sh"
    awk '/^: "\$\{EIGS_SECTION_TIME:=1\}"/{copy=1} /^# Runaway guard/{copy=0} copy{print}' \
        "$RUNNER" >> "$stub/tests/run_all_tests.sh"
    for i in $(seq 1 "$CHUNK_FLOOR"); do
        printf '# [%s] Stub\nif [ %s -le 3 ] || [ "${SP_HIDE_SECTIONS:-0}" = 0 ]; then\n    echo "[%s] Stub"\nfi\n' \
            "$((9000 + i))" "$i" "$((9000 + i))" >> "$stub/tests/run_all_tests.sh"
    done
    printf '# Final guard (#681)\n__eigs_section_close\nexit 0\n' >> "$stub/tests/run_all_tests.sh"
    expect_ok 'control: static source count agrees with visible shard headers' \
        env EIGS_SUITE_SHARD=2/3 SP_HIDE_SECTIONS=0 bash "$stub/tests/run_all_tests.sh"
    expect_red 'runner: hidden section bodies violate planner header count' 'section plan promised' \
        env EIGS_SUITE_SHARD=2/3 SP_HIDE_SECTIONS=1 bash "$stub/tests/run_all_tests.sh"
    echo 'SECTION_TIME: [only-one] 0.01' > "$dir/partial.log"
    expect_red 'print_weights: partial log cannot refresh table' 'only 1 SECTION_TIME' \
        "$0" --root "$SP_ROOT" --print-weights "$dir/partial.log"
    echo "section_plan selftest: checks=$((pass + fail)) failures=$fail"
    [ "$pass" -gt 0 ] && [ "$fail" -eq 0 ]
}

MODE='' ARG1='' ARG2='' ARG3='' SP_SHARDS='' SP_SHARD_K=''
while [ "$#" -gt 0 ]; do
    case "$1" in
        --root) SP_ROOT=$(cd "$2" && pwd); RUNNER="$SP_ROOT/tests/run_all_tests.sh"; CI_FILE="$SP_ROOT/.github/workflows/ci.yml"; shift 2 ;;
        --runner) RUNNER="$2"; shift 2 ;;
        --ci-file) CI_FILE="$2"; shift 2 ;;
        --quiet) VERBOSE=0; shift ;;
        --chunks|--skip-audit|--selftest) MODE="$1"; shift ;;
        --shards) SP_SHARDS="$2"; shift 2 ;;
        --shard) SP_SHARD_K="$2"; shift 2 ;;
        --check) MODE='--shard-check'; shift ;;
        --shard-owner|--print-weights) MODE="$1"; ARG1="$2"; shift 2 ;;
        --section) ARG2="$2"; shift 2 ;;
        --run) WEIGHTS_RUN="$2"; shift 2 ;;
        --head) WEIGHTS_HEAD="$2"; shift 2 ;;
        --weights-file) WEIGHTS_FILE="$2"; shift 2 ;;
        --emit-shard) MODE="$1"; ARG1="$2"; ARG2="$3"; ARG3="$4"; shift 4 ;;
        --print-waivers) SP_PRINT_WAIVERS=1; shift ;;
        *) die "unknown argument '$1'" ;;
    esac
done
[ -n "$MODE" ] || { [ -n "$SP_SHARDS" ] && [ -n "$SP_SHARD_K" ] && MODE='--shard-plan'; }
[ -n "$MODE" ] || die 'no mode given (see header)'
[ -f "$RUNNER" ] || die "runner not found: $RUNNER"
case "$MODE" in
    --chunks)
        W=$(sp_workdir chunks); derive_chunks "$RUNNER" > "$W/chunks"
        verify_partition "$RUNNER" "$W/chunks"; check_chunk_count "$W/chunks"
        [ "$VERBOSE" = 0 ] || cat "$W/chunks"
        echo "CHUNKS: examined=$(grep -c '[0-9]' "$W/chunks") floor=$CHUNK_FLOOR partition=verified" ;;
    --skip-audit)
        W=$(sp_workdir audit); skip_audit "$RUNNER" "$W"
        echo "SKIP AUDIT: emitters examined=$SP_SKIP_EMITS floor=$SKIP_EMIT_FLOOR; routes examined=$SP_SKIP_ROUTED floor=$SKIP_ROUTED_FLOOR; waivers=$SP_SKIP_WAIVERS_USED; unaccounted=0" ;;
    --shard-check) [ -n "$SP_SHARDS" ] || die '--check needs --shards N'; shard_check "$SP_SHARDS" ;;
    --shard-plan) build_shard_plan "$SP_SHARD_K" "$SP_SHARDS" ;;
    --shard-owner) shard_owner "$ARG1" "$ARG2" ;;
    --print-weights) print_weights "$ARG1" ;;
    --emit-shard) emit_shard "$ARG1" "$ARG2" "$ARG3" ;;
    --selftest) selftest ;;
esac
