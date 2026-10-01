#!/usr/bin/env bash
# Keep the release runbook explicit about the independently automated tap.
set -eu
cd "$(dirname "$0")/.."

check_file() {
    file=$1
    failed=0
    for phrase in \
        'track the latest release automatically' \
        'bump-formula.yml' \
        'workflow_dispatch' \
        "GitHub's public API" \
        'computes the formula' \
        'sha256' \
        'brew test-bot' \
        'dispatch `bump-formula.yml`'
    do
        if ! grep -Fq "$phrase" "$file"; then
            echo "release_skill_check: RED: missing required guidance: $phrase"
            failed=1
        fi
    done
    return "$failed"
}

if [ "${1:-}" = --selftest ]; then
    scratch=$(mktemp "${TMPDIR:-/tmp}/release-skill.XXXXXX")
    trap 'rm -f "$scratch"' EXIT HUP INT TERM
    cp .claude/skills/release/SKILL.md "$scratch"
    sed 's/brew test-bot/brew verification/' "$scratch" > "$scratch.mutant"
    mv "$scratch.mutant" "$scratch"
    if check_file "$scratch" > /dev/null 2>&1; then
        echo 'release_skill_check selftest: RED: missing test-bot guidance was accepted'
        exit 1
    fi
    echo 'release_skill_check selftest: PASS: missing test-bot guidance rejected'
    exit 0
fi

check_file "${1:-.claude/skills/release/SKILL.md}"
echo 'release_skill_check: PASS'
