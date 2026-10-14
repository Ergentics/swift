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

step "Installing build dependencies"

# Build dependencies, from swiftlang/swift-docker swift-ci/main/ubuntu/24.04.
export DEBIAN_FRONTEND=noninteractive
apt-get -q update
apt-get -q install -y \
  build-essential cmake curl git icu-devtools libc++-18-dev libc++abi-18-dev \
  libcurl4-openssl-dev libedit-dev libicu-dev libncurses5-dev libpython3-dev \
  libsqlite3-dev libxml2-dev ninja-build pkg-config python3 python3-pip \
  python3-pkg-resources python3-psutil python3-setuptools python3-six rsync \
  swig systemtap-sdt-dev tzdata uuid-dev zip

sccache=()
step "Installing sccache"
if [[ $(uname -m) == x86_64 ]]; then
  version=v0.17.0
  name=sccache-$version-x86_64-unknown-linux-musl
  curl -fsSL -o /tmp/sccache.tar.gz \
    "https://github.com/mozilla/sccache/releases/download/$version/$name.tar.gz"
  echo "67c4a96dd237c1f518f6b36083f270f9976d516f1e57fce891755ea782e50006  /tmp/sccache.tar.gz" |
    sha256sum -c -
  tar -xzf /tmp/sccache.tar.gz -C /tmp
  install -m 755 "/tmp/$name/sccache" /usr/local/bin/sccache
  sccache --start-server
  sccache=(--sccache)
fi

# The checkout is owned by the runner user, not by root in this container.
git config --global --add safe.directory '*'

cd "$SWIFT_SOURCE_ROOT/swift"
step "Cloning the other repositories"
utils/update-checkout --clone --skip-history --skip-tags \
  --scheme "$scheme" --skip-repository swift

case $mode in
  compiler)
    # The compiler and standard library only, packaged as an install tree.
    args=(
      --release --assertions --no-swift-stdlib-assertions
      --skip-build-benchmarks
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
if [[ ${#sccache[@]} -gt 0 ]]; then
  sccache --show-stats
fi
if [[ $status -eq 124 ]]; then
  echo "::error::Build ran out of time. Re-run to continue from the sccache cache, raise the minutes input, or use a larger runner."
fi
exit "$status"
