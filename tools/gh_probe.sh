#!/usr/bin/env bash
# gh_probe.sh — ONE definition of "this lane can reach GitHub", sourced by the
# GitHub-facing gates AND by their callers.
#
# WHY THIS EXISTS (round 4 of #1207/#1155, blind critic Fable, 2026-09-21):
# rounds 1-3 built a caller that asserts a gate's population line. Round 3's
# caller accepted the gate's OWN SKIP TOKEN as a population line — so removing
# only the live GitHub walk from tools/roadmap_check.sh and dressing it as a
# named skip (`gh_authenticated() { return 1; }`) passed `[99zd]` ON A BOX
# WHERE `gh` IS AUTHENTICATED. The caller had no opinion about whether the skip
# was TRUE, because it had no probe of its own: it already probed PyYAML for
# itself and simply believed the gate about `gh`.
#
# The fix is this file. The gates and the callers now ask the SAME question
# through the SAME code, and the caller compares the answer with what the gate
# claims. A gate that skips on a lane where the caller can reach GitHub is red
# BY NAME ("the caller can reach GitHub; the gate skipped anyway").
#
# AUTHENTICATED IS NOT INSTALLED, and neither is "gh auth status exits 0".
# Measured on the dev box 2026-09-21: with GH_TOKEN set to a bogus value
# `gh auth status` prints "The token in GH_TOKEN is invalid." and STILL EXITS
# 0. So the probe also makes one cheap authenticated call. `rate_limit` and
# not `user`: it costs no rate limit, it answers for a personal token AND for
# a workflow's GITHUB_TOKEN (which is FORBIDDEN from `/user` — probing with
# that would have made the daily lane skip itself), and it is a 401 on a bad
# token.
#
# THE BOUNDARY. This probe answers "can THIS process reach GitHub". It cannot
# answer "did that other process actually call GitHub": a gate that prints a
# `gh-api:` token without making a call is outside the reach of any caller.
# That is what the blind-critic rounds and the gates' own planted faults are
# for. See docs/CI.md, "What the caller can and cannot prove".
#
# Usage:
#   . tools/gh_probe.sh            # sourced: defines the three functions below
#   bash tools/gh_probe.sh --state # prints one of the state words, exit 0 iff
#                                  # the state is `authenticated`

# The state word, on stdout, with no trailing newline. Exit 0 iff authenticated.
#   no-gh               `gh` is not on PATH
#   gh-unauthenticated  `gh` is there and has no working credentials
#   authenticated       `gh auth status` AND one real API call both succeeded
gh_probe_state() {
    if ! command -v gh >/dev/null 2>&1; then
        printf 'no-gh'
        return 1
    fi
    if ! gh auth status >/dev/null 2>&1; then
        printf 'gh-unauthenticated'
        return 1
    fi
    if ! gh api rate_limit >/dev/null 2>&1; then
        printf 'gh-unauthenticated'
        return 1
    fi
    printf 'authenticated'
    return 0
}

# The predicate the gates call. Silent; the state word is the caller's business.
gh_probe_authenticated() {
    gh_probe_state >/dev/null 2>&1
}

# Does this LANE DECLARE that it holds a credential? This is an INDEPENDENT
# signal from the probe above — it reads the environment the workflow set, not
# `gh`'s answer — so a caller can cross-check the two. A lane that exports
# GH_TOKEN/GITHUB_TOKEN and then cannot reach GitHub is broken (or the probe
# has been gutted), and that is a finding rather than a skip.
gh_probe_token_declared() {
    [ -n "${GH_TOKEN:-}" ] || [ -n "${GITHUB_TOKEN:-}" ]
}

# Executed rather than sourced: the CLI form, for callers that are not shell.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
    case "${1:-}" in
        --state)
            gh_probe_state
            rc=$?
            echo
            exit $rc
            ;;
        *)
            echo "usage: $0 --state   (or: . $0 to get gh_probe_authenticated)" >&2
            exit 2
            ;;
    esac
fi
