#!/usr/bin/env bash
# Changelog fragments (#1268): a PR adds changes/<category>/<issue>-<slug>.md and never edits CHANGELOG.md,
# so two PRs cannot conflict on it. Two modes, one definition of "fragment":
#   changelog_fragments.sh check [base-ref]      the PR gate (base default origin/main, via merge-base)
#   changelog_fragments.sh cut <version> <date>  the release cut: fold every fragment into CHANGELOG.md,
#                                                bump VERSION, delete the fragments (date is YYYY-MM-DD, given, not read)
# The category dir -> "### " heading mapping is heading() below and nowhere else. `internal` is the opt-out for
# a src/lib change that needs no entry: it satisfies the gate and the cut deletes it without assembling it.
set -u
cd "$(dirname "$0")/.." || exit 2
CATS="breaking added changed deprecated removed fixed security documentation"
NAME='^[0-9]+-[a-z0-9][a-z0-9-]*\.md$'
die() { echo "changelog: ABORTED: $*" >&2; exit 2; }
heading() { case $1 in breaking) echo "Breaking changes";; added) echo Added;; changed) echo Changed;;
    deprecated) echo Deprecated;; removed) echo Removed;; fixed) echo Fixed;; security) echo Security;;
    documentation) echo Documentation;; esac; }
shape() { [ "$(head -c2 "$1")" = "- " ] && [ -z "$(tail -c1 "$1")" ]; }   # an entry starts "- " and ends in a newline

assemble() {   # <root> <version> <date>: the whole cut, on <root> (the real tree, or a base checkout to reproduce it)
    local r=$1 v=$2 d=$3 sec e c f names
    [[ $v =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && $d =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { echo "changelog: bad version/date '$v' '$d'"; return 1; }
    [ "$(grep -c '^## \[Unreleased\]$' "$r/CHANGELOG.md")" = 1 ] || { echo "changelog: need exactly one '## [Unreleased]'"; return 1; }
    grep -q "^## \[$v\]" "$r/CHANGELOG.md" && { echo "changelog: [$v] already has a section"; return 1; }
    for e in $(ls -A "$r/changes"); do   # refuse, never skip, what is not a known category
        case " README.md internal $CATS " in *" $e "*) ;; *) echo "changelog: unknown entry changes/$e"; return 1;; esac
    done
    sec=$(mktemp) || return 1
    for c in $CATS internal; do
        [ -d "$r/changes/$c" ] || continue
        names=$(cd "$r/changes/$c" && ls -A | LC_ALL=C sort -t- -k1,1n -k2)   # issue number (numeric), then slug
        [ -n "$names" ] || continue
        [ "$c" = internal ] || printf '### %s\n\n' "$(heading "$c")" >> "$sec"
        for f in $names; do
            [[ $f =~ $NAME ]] && shape "$r/changes/$c/$f" || { echo "changelog: bad fragment changes/$c/$f"; rm -f "$sec"; return 1; }
            [ "$c" = internal ] || cat "$r/changes/$c/$f" >> "$sec"
        done
        [ "$c" = internal ] || echo >> "$sec"
    done
    # Everything under [Unreleased] stays byte-identical and becomes the head of the new section; the
    # fragment headings follow it, just before the previous release.
    awk -v v="$v" -v d="$d" -v sec="$sec" '
        /^## \[Unreleased\]$/ { print; print ""; print "## [" v "] - " d; u = 1; next }
        u && /^## \[/ { while ((getline l < sec) > 0) print l; u = 0 }
        { print }
        END { if (u) while ((getline l < sec) > 0) print l }' "$r/CHANGELOG.md" > "$r/CHANGELOG.md.new" \
        && mv "$r/CHANGELOG.md.new" "$r/CHANGELOG.md" && printf '%s\n' "$v" > "$r/VERSION" \
        && find "$r/changes" -mindepth 2 -type f -name '*.md' -delete
    local rc=$?; rm -f "$sec"; return $rc
}

reproduces() {   # <merge-base>: is the working CHANGELOG.md exactly what the cut makes of the base tree?
    local t v d rc; t=$(mktemp -d) || die "mktemp"
    v=$(cat VERSION); d=$(sed -n "s/^## \[$v\] - \(.*\)$/\1/p" CHANGELOG.md)
    git archive "$1" CHANGELOG.md VERSION changes 2>/dev/null | tar -x -C "$t" 2>/dev/null \
        && assemble "$t" "$v" "$d" >/dev/null && cmp -s "$t/CHANGELOG.md" CHANGELOG.md
    rc=$?; rm -rf "$t"; return $rc
}

check() {
    local base=${1:-origin/main} mb t st p c f n=0 src=0 add=0 chlog=0 ver=0 cut=0 bad=0
    mb=$(git merge-base "$base" HEAD) || die "no merge-base with $base (git fetch origin main)"
    t=$(mktemp -d) || die "mktemp"; trap "rm -rf '$t'" EXIT
    git diff -z --no-renames --name-status "$mb" > "$t/l" || die "git diff $mb failed"
    git ls-files -z --others --exclude-standard | while IFS= read -r -d '' p; do printf 'A\0%s\0' "$p"; done >> "$t/l"
    while IFS= read -r -d '' st && IFS= read -r -d '' p; do
        n=$((n + 1))
        case $p in
            CHANGELOG.md) chlog=1 ;;
            VERSION) ver=1 ;;
            src/*|lib/*) src=1 ;;
            changes/README.md) ;;
            changes/*)
                [ "$st" = D ] && continue
                c=${p#changes/}; c=${c%%/*}; f=${p##*/}
                if [[ $p =~ ^changes/[a-z]+/[^/]+$ && $f =~ $NAME ]] && shape "$p" \
                    && case " $CATS internal " in *" $c "*) true;; *) false;; esac
                then [ "$st" = A ] && add=$((add + 1))
                else echo "FAIL $p: a fragment is changes/<category>/<issue>-<slug>.md, category one of: $CATS internal; it starts '- ' and ends in a newline"; bad=1
                fi ;;
        esac
    done < "$t/l"
    if [ $chlog = 1 ]; then
        if [ $ver = 1 ] && reproduces "$mb"; then cut=1
        else echo "FAIL CHANGELOG.md is edited directly. Add changes/<category>/<issue>-<slug>.md instead (see changes/README.md); only the release cut (tools/changelog_fragments.sh cut <version> <date>, which also bumps VERSION) may write it"; bad=1
        fi
    fi
    if [ $src = 1 ] && [ $add = 0 ] && [ $cut = 0 ]; then
        echo "FAIL src/ or lib/ changed without a changelog fragment. Add changes/<category>/<issue>-<slug>.md holding the entry text (category: $CATS), or changes/internal/<issue>-<slug>.md ('- why no entry') if the change needs none"; bad=1
    fi
    echo "changelog: examined $n changed path(s) against $mb; $add fragment(s) added; cut=$cut"
    [ "$bad" = 0 ]
}

case ${1:-} in
    check) shift; check "$@" ;;
    cut) [ $# = 3 ] || die "usage: cut <version> <date>"; assemble . "$2" "$3" || die "cut refused"; echo "changelog: cut $2 ($3)" ;;
    *) echo "usage: tools/changelog_fragments.sh check [base-ref] | cut <version> <YYYY-MM-DD>" >&2; exit 2 ;;
esac
