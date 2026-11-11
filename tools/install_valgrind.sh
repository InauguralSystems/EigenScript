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

# Valgrind is installed when Memcheck starts, not when the binary prints a
# version. With a libc6-dbg that does not match the installed libc6, or one
# that dpkg unpacked and could not configure, it prints its version and then
# dies at startup, and the gate that follows reads that as a regression.
memcheck_starts() {
  command -v valgrind >/dev/null 2>&1 && valgrind --version && valgrind --quiet /bin/true
}

verify() {
  memcheck_starts || { echo "::error::valgrind is installed but Memcheck does not start"; return 1; }
}

# A restored cache is deliberately installed without apt: this makes the warm
# path independent of package indexes and mirrors. The action only restores a
# cache when its candidate Valgrind version matches (see action.yml).
shopt -s nullglob
archives=("$archive_dir"/*.deb)
if ((${#archives[@]})); then
  echo "Installing Valgrind from cached .deb archives"
  if timeout 120 sudo dpkg -i "${archives[@]}" && memcheck_starts; then
    exit 0
  fi
  echo "::warning::the cached Valgrind archives did not install a working Valgrind; falling back to the network"
  # A dpkg -i that fails leaves what it unpacked: Valgrind on the PATH,
  # printing its version, unconfigured (#2341). apt does not fetch an archive
  # for a package in that state, so the directory saved afterwards could not
  # install Valgrind; told to reinstall it, apt stops with "Internal Error, No
  # file name for valgrind". So remove what the archives installed: the
  # install below then starts where a runner without a cache starts, and
  # fetches every archive again.
  cached_packages=()
  for archive in "${archives[@]}"; do
    name=$(dpkg-deb -f "$archive" Package 2>/dev/null) && [ -n "$name" ] && cached_packages+=("$name")
  done
  if ((${#cached_packages[@]})); then
    timeout 120 sudo dpkg --remove "${cached_packages[@]}" ||
      echo "::warning::could not remove what the cached archives had installed"
  fi
  sudo rm -f "$archive_dir"/*.deb
elif memcheck_starts; then
  # Some images may already contain Valgrind. This needs neither cache nor mirror.
  exit 0
fi

apt_install() {
  # Noble's stripped loader makes libc6-dbg mandatory for Memcheck startup.
  timeout 90 sudo apt-get "$@" \
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
  -o "Dir::Etc::sourcelist=$alternative_sources"
  -o Dir::Etc::sourceparts=-
)

# actions/cache saves this directory as the runner user. apt leaves its lock
# file and partial/ owned by root and _apt and unreadable, and the save's tar
# then fails with exit 2, so the warm path would never be populated: the first
# cold run on Actions measured exactly that. Keep only the .debs, owned by
# the runner.
publish_archives() {
  sudo rm -rf "$archive_dir/partial" "$archive_dir/lock"
  sudo chown -R "$(id -u):$(id -g)" "$archive_dir"
}

# #987: try the image's current index first; only refresh on failure. Keep all
# operations bounded so a true setup failure remains loud and cannot look like
# a passing (or even executed) regression gate.
if apt_install; then
  verify || exit 1
  publish_archives
  exit 0
fi
for attempt in 1 2 3; do
  echo "::warning::valgrind not in the current index; refreshing (attempt $attempt)"
  if apt_update "${alternative_options[@]}" && apt_install "${alternative_options[@]}"; then
    verify || exit 1
    publish_archives
    exit 0
  fi
  sleep $((attempt * 5))
done
setup_failure
