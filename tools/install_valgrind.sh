#!/usr/bin/env bash
# Install Valgrind while retaining every archive apt needs for the install.
# The archive directory is restored/saved by .github/actions/install-valgrind.
set -uo pipefail

archive_dir=${VALGRIND_DEB_CACHE_DIR:-${RUNNER_TEMP:-/tmp}/valgrind-debs}
mkdir -p "$archive_dir/partial"

setup_failure() {
  echo "::error::SETUP FAILURE — could not install valgrind after 3 bounded attempts. This is NOT a regression detected by the gate; the gate never ran."
  exit 1
}

verify() {
  valgrind --version
}

# A restored cache is deliberately installed without apt: this makes the warm
# path independent of package indexes and mirrors. A cache is only reusable on
# the exact hosted-runner image and candidate version (see action.yml).
shopt -s nullglob
archives=("$archive_dir"/*.deb)
if ((${#archives[@]})); then
  echo "Installing Valgrind from cached .deb archives"
  if timeout 120 sudo dpkg -i "${archives[@]}" && command -v valgrind >/dev/null 2>&1 && verify; then
    exit 0
  fi
  echo "::warning::cached Valgrind archives were incomplete or corrupt; falling back to the network"
  sudo rm -f "$archive_dir"/*.deb
fi

# Some images may already contain Valgrind. This needs neither cache nor mirror.
if command -v valgrind >/dev/null 2>&1; then
  verify
  exit 0
fi

# Test-only apt options let the local evidence exercise a genuinely unavailable
# network. Production leaves this unset. Shell splitting is intentional: each
# whitespace-delimited option becomes one apt-get argument.
read -r -a apt_options <<< "${VALGRIND_APT_OPTIONS:-}"
apt_install() {
  timeout 120 sudo apt-get "${apt_options[@]}" \
    -o "Dir::Cache::archives=$archive_dir" install -y valgrind
}
apt_update() {
  timeout 60 sudo apt-get "${apt_options[@]}" update
}

# #987: try the image's current index first; only refresh on failure. Keep all
# operations bounded so a true setup failure remains loud and cannot look like
# a passing (or even executed) regression gate.
if apt_install; then
  verify || exit 1
  exit 0
fi
for attempt in 1 2 3; do
  echo "::warning::valgrind not in the current index; refreshing (attempt $attempt)"
  if apt_update && apt_install; then
    verify || exit 1
    exit 0
  fi
  sleep $((attempt * 5))
done
setup_failure
