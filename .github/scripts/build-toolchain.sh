#!/bin/bash
# Builds Swift inside the official swift container image, for the
# "Build toolchain" workflow.
#
# Usage: build-toolchain.sh <compiler|toolchain> <update-checkout scheme> <deadline>
#
# Expects the source root (this repository checked out as swift/) at
# SWIFT_SOURCE_ROOT and an empty build root at SWIFT_BUILD_ROOT. The build is
# stopped at <deadline> (seconds since the epoch) so the workflow still has
# time to save its sccache cache; re-running the workflow then reuses the
# cached C and C++ objects.
set -euo pipefail

mode=$1
scheme=$2
deadline=$3

step() {
  echo "== $(date -u +%H:%M:%S) $*"
}

# Everything here runs as root. Give the sources, the build and the cache back
# to whoever owns the mounted workspace (the runner user, or root under
# rootless Docker) so later steps and jobs can read and delete them.
finish() {
  if command -v sccache >/dev/null; then
    sccache --stop-server || true
  fi
  chown -R "$(stat -c %u:%g "$SWIFT_SOURCE_ROOT")" \
    "$SWIFT_SOURCE_ROOT" "$SWIFT_BUILD_ROOT" || true
  df -h "$SWIFT_SOURCE_ROOT" "$SWIFT_BUILD_ROOT" || true
}
trap finish EXIT

step "Installing build dependencies"

# Build dependencies, from swiftlang/swift-docker swift-ci/main/ubuntu/24.04.
export DEBIAN_FRONTEND=noninteractive
apt-get -q update
apt-get -q install -y \
  build-essential curl git icu-devtools libc++-18-dev libc++abi-18-dev \
  libcurl4-openssl-dev libedit-dev libicu-dev libncurses5-dev libpython3-dev \
  libsqlite3-dev libxml2-dev ninja-build pkg-config python3 python3-pip \
  python3-pkg-resources python3-psutil python3-setuptools python3-six rsync \
  swig systemtap-sdt-dev tzdata uuid-dev zip

# The same CMake as the cmake repository update-checkout clones. With an older
# one, build-script spends several minutes building CMake from source.
pip3 install -q --break-system-packages cmake==3.30.2

step "Installing sccache"
sccache=()
version=v0.17.0
case $(uname -m) in
  x86_64) sum=67c4a96dd237c1f518f6b36083f270f9976d516f1e57fce891755ea782e50006 ;;
  aarch64) sum=821a86343191aa1cbab74bd42f9e93c9a63bf85e4742945f40d3ae84193c1c77 ;;
  *) sum= ;;
esac
if [[ -n $sum ]]; then
  name=sccache-$version-$(uname -m)-unknown-linux-musl
  curl -fsSL -o /tmp/sccache.tar.gz \
    "https://github.com/mozilla/sccache/releases/download/$version/$name.tar.gz"
  echo "$sum  /tmp/sccache.tar.gz" | sha256sum -c -
  tar -xzf /tmp/sccache.tar.gz -C /tmp
  install -m 755 "/tmp/$name/sccache" /usr/local/bin/sccache
  sccache --start-server
  sccache=(--sccache)
else
  echo "::warning::No sccache for $(uname -m); a re-run will start from scratch."
fi

# The checkout is owned by the runner user, not by root in this container.
git config --global --add safe.directory '*'

cd "$SWIFT_SOURCE_ROOT/swift"
step "Cloning the other repositories"
# A re-run of a workflow run clones the same revisions as its first attempt, so
# the C and C++ objects in the sccache cache still match. The pinned revisions
# are saved with the cache.
pin=$SWIFT_BUILD_ROOT/checkout/$GITHUB_RUN_ID.json
if [[ -f $pin ]]; then
  utils/update-checkout --clone --skip-history --skip-tags \
    --config "$pin" --scheme pinned --skip-repository swift
else
  utils/update-checkout --clone --skip-history --skip-tags \
    --scheme "$scheme" --skip-repository swift
  mkdir -p "${pin%/*}"
  # Repositories that were not cloned are listed as "skip"; leave them out.
  utils/update-checkout --dump-hashes-config pinned | python3 -c '
import json, sys
config = json.load(sys.stdin)
repos = config["branch-schemes"]["pinned"]["repos"]
config["branch-schemes"]["pinned"]["repos"] = {
    name: rev for name, rev in repos.items() if rev != "skip"}
json.dump(config, sys.stdout, indent=1)' > "$pin.tmp"
  mv "$pin.tmp" "$pin"
fi

case $mode in
  compiler)
    # The compiler and standard library only, packaged as an install tree.
    # LLVM is cut down to what Swift needs: Clang and the x86 and Arm backends.
    args=(
      --release --assertions --no-swift-stdlib-assertions
      --skip-build-benchmarks
      --skip-build-clang-tools-extra --skip-build-compiler-rt --skip-build-lld
      "--llvm-targets-to-build=X86;AArch64"
      --install-swift --install-prefix=/usr
      --install-destdir="$SWIFT_BUILD_ROOT/install"
      --installable-package="$SWIFT_BUILD_ROOT/swift-compiler-linux.tar.gz"
    )
    ;;
  toolchain)
    # The full Linux toolchain, as ci.swift.org builds it without tests.
    args=(
      --preset=buildbot_linux,no_test
      install_destdir="$SWIFT_BUILD_ROOT/install"
      installable_package="$SWIFT_BUILD_ROOT/swift-toolchain-linux.tar.gz"
    )
    ;;
  *)
    echo "unknown build: $mode" >&2
    exit 2
    ;;
esac

# Don't package leftovers from an earlier build on a self-hosted runner.
rm -rf "$SWIFT_BUILD_ROOT/install" "$SWIFT_BUILD_ROOT"/swift-*-linux.tar.gz

seconds=$(( deadline - $(date +%s) ))
if (( seconds <= 0 )); then
  echo "::error::No time left to build. Raise the minutes input."
  exit 1
fi
step "Building for up to $(( seconds / 60 )) minutes"
status=0
timeout --signal=INT --kill-after=2m "$seconds" \
  utils/build-script "${sccache[@]}" "${args[@]}" || status=$?
step "Build finished with status $status"
if [[ $status -eq 124 ]]; then
  echo "::error::Build ran out of time. Re-run to continue from the sccache cache, raise the minutes input, or use a larger runner."
fi
exit "$status"
