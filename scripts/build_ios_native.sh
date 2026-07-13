#!/usr/bin/env bash
# Canonical iOS app build: pure Swift JoshuaRustDesk (replaces Flutter Runner).
# Bundle id com.joshuaji.rustdesk — install overwrites the old Flutter app.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="${HOME}/development/flutter/bin:${HOME}/.cargo/bin:/opt/homebrew/bin:${PATH}"
export VCPKG_ROOT="${VCPKG_ROOT:-$HOME/vcpkg}"
export IPHONEOS_DEPLOYMENT_TARGET=13.0
export RUSTFLAGS="${RUSTFLAGS:--C link-arg=-Wl,-undefined,dynamic_lookup}"

cd "$ROOT"
echo "==> Building liblibrustdesk.a (aarch64-apple-ios, flutter+hwcodec)"
rustup target add aarch64-apple-ios >/dev/null
cargo build --locked --features flutter,hwcodec --release --target aarch64-apple-ios --lib

echo "==> Generating Xcode project (apple/JoshuaRustDesk)"
cd apple/JoshuaRustDesk
xcodegen generate

echo "==> Building RustDesk (native iOS)"
xcodebuild \
  -project JoshuaRustDesk.xcodeproj \
  -scheme JoshuaRustDesk \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -allowProvisioningUpdates \
  CODE_SIGN_STYLE=Automatic \
  DEVELOPMENT_TEAM=GGUE5367V3 \
  PRODUCT_BUNDLE_IDENTIFIER=com.joshuaji.rustdesk \
  build

APP=$(find ~/Library/Developer/Xcode/DerivedData \
  -path '*JoshuaRustDesk*/Build/Products/Release-iphoneos/*.app' \
  2>/dev/null | head -1)
# Prefer product named RustDesk.app (PRODUCT_NAME) when both exist.
if [[ -d "${APP%/*}/RustDesk.app" ]]; then
  APP="${APP%/*}/RustDesk.app"
fi
echo "Built: ${APP:-unknown}"

if [[ "${1:-}" == "install" ]]; then
  IPAD="${IPAD_DEVICE:-0FA97996-0CEE-5B6A-9703-E6F2A9E28091}"
  if [[ -n "$APP" && -d "$APP" ]]; then
    echo "==> Installing over com.joshuaji.rustdesk (replaces Flutter build if present)"
    xcrun devicectl device install app --device "$IPAD" "$APP"
    xcrun devicectl device process launch --device "$IPAD" --terminate-existing com.joshuaji.rustdesk
    echo "Installed and launched on iPad"
  else
    echo "Could not locate .app for install"
    exit 1
  fi
fi
