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
  valgrind --version || { echo "::error::valgrind installed but not runnable"; return 1; }
}

# A restored cache is deliberately installed without apt: this makes the warm
# path independent of package indexes and mirrors. The action only restores a
# cache when its candidate Valgrind version matches (see action.yml).
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
read -r -a first_apt_options <<< "${VALGRIND_APT_FIRST_OPTIONS:-${VALGRIND_APT_OPTIONS:-}}"
apt_install() {
  local -a options=("$@")
  # Noble's stripped loader makes libc6-dbg mandatory for Memcheck startup.
  timeout 90 sudo apt-get "${options[@]}" \
    -o "Dir::Cache::archives=$archive_dir" \
    install -y --no-install-recommends valgrind libc6-dbg
}
apt_update() {
  timeout 45 sudo apt-get "$@" update
}

codename=$(. /etc/os-release && printf '%s' "$VERSION_CODENAME")
[ -n "$codename" ] || setup_failure
alternative_sources=$(mktemp)
trap 'rm -f "$alternative_sources"' EXIT
cat >"$alternative_sources" <<EOF
deb http://archive.ubuntu.com/ubuntu $codename main universe
deb http://archive.ubuntu.com/ubuntu $codename-updates main universe
deb http://archive.ubuntu.com/ubuntu $codename-backports main universe
deb http://security.ubuntu.com/ubuntu $codename-security main universe
EOF
alternative_options=(
  "${apt_options[@]}"
  -o "Dir::Etc::sourcelist=$alternative_sources"
  -o Dir::Etc::sourceparts=-
)

# #987: try the image's current index first; only refresh on failure. Keep all
# operations bounded so a true setup failure remains loud and cannot look like
# a passing (or even executed) regression gate.
if apt_install "${first_apt_options[@]}"; then
  verify || exit 1
  exit 0
fi
for attempt in 1 2 3; do
  echo "::warning::valgrind not in the current index; refreshing (attempt $attempt)"
  if apt_update "${alternative_options[@]}" && apt_install "${alternative_options[@]}"; then
    verify || exit 1
    exit 0
  fi
  sleep $((attempt * 5))
done
setup_failure
