#!/usr/bin/env bash
# Data-only operator preparation: create two NEW attached source checkouts.
set -euo pipefail
pkg=$(cd "$(dirname "$0")" && pwd)
carrier=$(git -C "$pkg" rev-parse --show-toplevel)
base=5cb91de8354d49340976ba085e6e6ddd3fe6b927
base_tree=4100f6320ef61469d267793fa7a6b44f813410a1
workspace=${1:?usage: prepare-inputs.sh NEW-ABSOLUTE-WORKSPACE}
case "$workspace" in /*) ;; *) echo 'workspace must be absolute' >&2; exit 2;; esac
[ ! -e "$workspace" ] || { echo 'workspace must be new' >&2; exit 2; }
# Cloud may provide a snapshot with neither historical objects nor remotes.
# The repository is public; fetch only the immutable baseline by canonical URL.
if ! git -C "$carrier" cat-file -e "$base^{commit}" 2>/dev/null; then
    git -C "$carrier" fetch --no-tags --depth=1 \
        https://github.com/InauguralSystems/EigenScript.git "$base"
fi
[ "$(git -C "$carrier" rev-parse --verify "$base^{commit}")" = "$base" ] || {
    echo 'frozen baseline commit identity differs' >&2; exit 2;
}
[ "$(git -C "$carrier" rev-parse --verify "$base^{tree}")" = "$base_tree" ] || {
    echo 'frozen baseline tree identity differs' >&2; exit 2;
}
mkdir "$workspace"
for arm in candidate baseline; do
    git clone --shared --no-checkout --separate-git-dir "$workspace/$arm-gitdir" "$carrier" "$workspace/$arm"
    # A snapshot clone may omit an object reachable only through FETCH_HEAD.
    if ! git -C "$workspace/$arm" cat-file -e "$base^{commit}" 2>/dev/null; then
        git -C "$workspace/$arm" fetch --no-tags --depth=1 "$carrier" "$base"
    fi
    git -C "$workspace/$arm" checkout -b "validation-1444-$arm" "$base"
done
git -C "$workspace/candidate" apply --check --index "$pkg/candidate.patch"
git -C "$workspace/candidate" apply --index "$pkg/candidate.patch"
python3 -B "$pkg/validate.py" --candidate "$workspace/candidate" --baseline "$workspace/baseline"
printf 'Prepared source inputs only; execute exactly:\npython3 -B %q --candidate %q --baseline %q --evidence %q --execute\n' \
    "$pkg/validate.py" "$workspace/candidate" "$workspace/baseline" "$workspace/evidence"
