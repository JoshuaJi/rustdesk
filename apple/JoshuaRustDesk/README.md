# RustDesk (native iOS)

Pure Swift + Rust client. **This is the iOS app** — same bundle id as the old Flutter Runner (`com.joshuaji.rustdesk`), so installing it replaces the Flutter build on device.

## Build & install

```bash
# from repo root
./scripts/build_ios_native.sh          # build only
./scripts/build_ios_native.sh install  # build + install + launch on iPad
```

Optional: `IPAD_DEVICE=<udid> ./scripts/build_ios_native.sh install`

## Layout

| Path | Role |
|------|------|
| `Sources/` | SwiftUI + Metal remote session |
| `Bridging/` | C ABI header → `liblibrustdesk.a` |
| `Resources/` | Info.plist, AppIcon |

Rust core is built with `--features flutter,hwcodec` into `target/aarch64-apple-ios/release/liblibrustdesk.a` (session engine shared with Flutter desktop; UI is not Flutter).

## Flutter iOS

`flutter/ios` is legacy for this product line. Prefer this target for day-to-day iPad work.
