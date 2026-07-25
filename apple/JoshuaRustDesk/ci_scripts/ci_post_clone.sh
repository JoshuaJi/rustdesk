#!/bin/bash
set -euo pipefail

REPO_ROOT="${CI_PRIMARY_REPOSITORY_PATH:-$(cd "$(dirname "$0")/../../.." && pwd)}"
VCPKG_COMMIT_ID="120deac3062162151622ca4860575a33844ba10b"

export PATH="${HOME}/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:${PATH}"
export IPHONEOS_DEPLOYMENT_TARGET=16.0

echo "==> Initializing submodules"
git -C "$REPO_ROOT" submodule update --init --recursive

if ! command -v nasm >/dev/null || ! command -v yasm >/dev/null; then
  echo "==> Installing native build tools"
  brew install nasm yasm
fi

if ! command -v rustup >/dev/null; then
  echo "==> Installing Rust"
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs |
    sh -s -- -y --profile minimal --default-toolchain stable
fi

rustup target add aarch64-apple-ios

export VCPKG_ROOT="${HOME}/vcpkg"
if [[ ! -d "$VCPKG_ROOT/.git" ]]; then
  echo "==> Cloning vcpkg"
  git clone https://github.com/microsoft/vcpkg.git "$VCPKG_ROOT"
fi

if ! git -C "$VCPKG_ROOT" cat-file -e "${VCPKG_COMMIT_ID}^{commit}" 2>/dev/null; then
  git -C "$VCPKG_ROOT" fetch origin "$VCPKG_COMMIT_ID"
fi
git -C "$VCPKG_ROOT" checkout --detach "$VCPKG_COMMIT_ID"

if [[ ! -x "$VCPKG_ROOT/vcpkg" ]]; then
  echo "==> Bootstrapping vcpkg"
  "$VCPKG_ROOT/bootstrap-vcpkg.sh" -disableMetrics
fi

echo "==> Installing iOS native dependencies"
(
  cd "$REPO_ROOT"
  "$VCPKG_ROOT/vcpkg" install \
    --triplet arm64-ios \
    --x-install-root="$VCPKG_ROOT/installed"
)

echo "==> Building Rust core"
"$REPO_ROOT/scripts/build_ios_native.sh" rust-only
