#!/bin/bash
# Mechanical doc-drift audit — cheap greps for the staleness classes
# that have actually occurred (found v0.24.0-vs-v0.26.0 CLAUDE.md drift
# the day it was written). Exit nonzero on drift. Runs in the suite
# ([98]) and is cron-able: the LLM-free half of "check for stale docs
# on its own"; prose-level drift needs the scheduled headless audit.
cd "$(dirname "$0")/.." || exit 1
drift=0

# 1. Every stdlib module has a STDLIB.md heading.
for m in lib/*.eigs; do
    stem=$(basename "$m")
    if ! grep -q "lib/$stem" docs/STDLIB.md; then
        echo "DRIFT: lib/$stem has no docs/STDLIB.md entry"
        drift=1
    fi
done

# 2. CLAUDE.md's "Latest release" line names the latest tag.
#
# `-c safe.directory='*'`: CI runs this inside a container (ci.yml `container:`)
# where the checkout is owned by another uid, so a plain `git tag` dies with
# "fatal: detected dubious ownership". actions/checkout registers the path on
# the RUNNER's global config, which the container user never reads.
#
# That failure used to be INVISIBLE: git wrote to stderr, `$tag` came back
# empty, and `[ -n "$tag" ]` skipped the comparison — so this check silently did
# not run in CI while the section still printed PASS. An empty result and "no
# drift" have to be distinguishable, or the gate measures nothing and says so in
# the language of success.
if ! git -c safe.directory='*' rev-parse --git-dir >/dev/null 2>&1; then
    if [ -e .git ]; then
        echo "BROKEN: git will not read this repository — the 'Latest release' check cannot run"
        drift=1
    else
        echo "NOTE: not a git checkout; skipping the 'Latest release' tag comparison"
    fi
else
    tag=$(git -c safe.directory='*' tag --sort=-v:refname | head -1)
    if [ -z "$tag" ]; then
        # A tagless clone (shallow / fresh init) is legitimate; say so rather
        # than passing quietly, so "no tags fetched" cannot look like "in sync".
        echo "NOTE: repository has no tags; skipping the 'Latest release' comparison"
    elif ! grep -q "Latest release: ${tag}" CLAUDE.md; then
        echo "DRIFT: CLAUDE.md 'Latest release' line is not ${tag}"
        drift=1
    fi
fi

# 3. A released VERSION always has its CHANGELOG section.
v=$(cat VERSION)
if ! grep -q "^## \[$v\]" CHANGELOG.md; then
    echo "DRIFT: CHANGELOG.md has no [$v] section for the current VERSION"
    drift=1
fi

# 4. README's "N-module standard library" headline equals its own table.
rows=$(grep -c '^| `lib/' README.md)
claim=$(grep -oE '[0-9]+-module standard library' README.md | grep -oE '^[0-9]+')
if [ -n "$claim" ] && [ "$claim" != "$rows" ]; then
    echo "DRIFT: README claims ${claim}-module stdlib but its table has ${rows} rows"
    drift=1
fi

# 5. docs/llms.txt (the single-file model reference, #403) stamps the current
# version, so it can't silently drift from the language it describes.
if [ -f docs/llms.txt ] && ! grep -q "EigenScript v$(cat VERSION)" docs/llms.txt; then
    echo "DRIFT: docs/llms.txt is not stamped 'EigenScript v$(cat VERSION)'"
    drift=1
fi

# 6. ARCHITECTURE.md's raw "N modules in `lib/`" count equals the tree (#833).
# Distinct from check 4: README's headline is pinned to its own curated table,
# this one is the unfiltered file count, and it had drifted 73 -> 76 silently
# because nothing looked at it. Ungated boundaries drift; gated ones don't.
arch_files=$(ls lib/*.eigs 2>/dev/null | wc -l | tr -d ' ')
arch_claim=$(grep -oE 'The [0-9]+ modules in `lib/`' docs/ARCHITECTURE.md | grep -oE '[0-9]+')
if [ -z "$arch_claim" ]; then
    echo "DRIFT: docs/ARCHITECTURE.md has no 'The N modules in \`lib/\`' claim to check"
    drift=1
elif [ "$arch_claim" != "$arch_files" ]; then
    echo "DRIFT: ARCHITECTURE.md claims ${arch_claim} lib/ modules but the tree has ${arch_files}"
    drift=1
fi

# 7. Heuristic lexer parse-error text check.
# For each line containing g_parse_errors++, mark it matched when one
# eigs_record_first_error(_at)( spelling appears in the preceding four
# physical lines, then flag a mismatch in the number of matched increment
# lines. This is deliberately only a text count: it does not strip comments
# or literals, parse control flow, require one block, localise an offender,
# or prove one-to-one recorder ownership.
lexer_parse_errors=$(grep -Ec 'g_parse_errors[[:space:]]*\+\+' src/lexer.c)
lexer_recorded_errors=$(awk '
{
    if ($0 ~ /g_parse_errors[[:space:]]*\+\+/) {
        for (i = NR - 1; i >= NR - 4 && i > 0; i--) {
            if (lines[i] ~ /eigs_record_first_error(_at)?[[:space:]]*\(/) {
                recorded++
                break
            }
        }
    }
    lines[NR] = $0
}
END { print recorded + 0 }
' src/lexer.c)
if [ "$lexer_parse_errors" -ne "$lexer_recorded_errors" ]; then
    echo "DRIFT: src/lexer.c has ${lexer_parse_errors} parse-error increments but only ${lexer_recorded_errors} nearby first-error recorders"
    drift=1
fi
# Vacuity floor (#956): both counts derive from the same file, so a rename of
# src/lexer.c or a refactor of the increments behind a helper collapses both
# sides to 0 and the equality above stays green while examining nothing.
# src/lexer.c has 8 increments today; 6 leaves refactoring room while still
# catching the collapse. Floor, not exact pin: adding an increment needs no edit
# here, only removing coverage does.
if [ "${lexer_parse_errors:-0}" -lt 6 ]; then
    echo "DRIFT: lexer parse-error audit examined ${lexer_parse_errors:-0} increments (expected >= 6) — did src/lexer.c move, or the increments change shape?"
    drift=1
fi

exit $drift
