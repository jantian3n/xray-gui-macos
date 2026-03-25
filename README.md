# Xray GUI macOS

Native macOS rewrite of the Android-first Xray GUI project.

## Current Direction

This repo is now moving toward a full `Swift + SwiftUI + AppKit + NetworkExtension` stack.

What is already in place:

- the macOS app entry point is native Swift, not a Flutter window anymore;
- the current window and menu are hosted by SwiftUI/AppKit;
- a first Swift implementation now parses `vless://` links and script-style outbound JSON;
- a first Swift implementation now compiles Xray JSON for macOS proxy modes;
- saved node snapshots are now persisted by the native app;
- the native app can now start a local `xray` subprocess and stream runtime logs;
- `系统代理` mode now starts wiring through a native macOS proxy manager with snapshot/restore;
- a first `PacketTunnel` NetworkExtension target is now part of the Xcode project;
- the host app now manages Packet Tunnel preferences through `NETunnelProviderManager`;
- the old Flutter/Dart code is still kept in the repo as migration reference.

What is not fully migrated yet:

- subscriptions and richer profile editing;
- deeper runtime validation and production packaging polish;
- the actual Packet Tunnel dataplane that forwards traffic instead of only wiring the control plane.

## Quick Start

1. Install full Xcode on macOS.
2. Open `macos/Runner.xcodeproj` in Xcode.
3. Run the `Runner` target.

The repository still contains:

- `assets/bin/macos/xray` for bundled runtime experiments;
- `lib/` as the legacy Flutter reference implementation;
- `scripts/` from the earlier migration stage.

The native app now treats bundled assets as a signed baseline only:

- the built-in `xray` binary and bootstrap geodata are copied from the app bundle;
- runtime updates are written into `~/Library/Application Support/xray_gui/managed/`;
- the next runtime launch prefers those managed files, so signed `.app` contents stay untouched.

## Repository Layout

```text
assets/
  bootstrap-geodata/
  bin/
lib/
  legacy Flutter/Dart reference logic
macos/
  native Swift macOS app target
scripts/
test/
```

## Current Milestone

The native macOS shell can already:

- host a real SwiftUI window;
- accept pasted node text;
- parse imported node content through Swift logic;
- save imported nodes into native local storage;
- generate a pretty-printed Xray JSON preview through Swift logic;
- start and stop a native `xray` runtime flow;
- install and manage a Packet Tunnel configuration from the native host app;
- show runtime logs inside the native UI.

This is the foundation for the next migration steps.

## Next Work

- move subscription import and richer profile management to Swift;
- harden runtime behavior, startup validation, and recovery UX;
- move the Packet Tunnel dataplane into the extension so VPN mode becomes truly usable;
- finish signing, packaging, and distribution for a real macOS `.app`.

## Signed Release

Use `scripts/release_macos_app.sh` to archive, package, and optionally notarize the macOS app.
The script now outputs both a `.zip` and a GitHub-friendly `.dmg`.

Required environment for a real signed build:

- `XRAY_GUI_DEVELOPMENT_TEAM`: your Apple Developer team id;
- `XRAY_GUI_PRODUCT_BASE_BUNDLE_IDENTIFIER`: your own base bundle id, for example `dev.example.xraygui`;
- optionally `XRAY_GUI_CODE_SIGN_IDENTITY`: defaults to `Developer ID Application`;
- optionally `XRAY_GUI_DMG_VOLUME_NAME`: defaults to `Xray GUI macOS`;
- optionally `XRAY_GUI_ALLOW_PROVISIONING_UPDATES=1` if Xcode needs to fetch/update profiles;
- optionally `XRAY_GUI_NOTARY_PROFILE`: `notarytool` keychain profile name for notarization.

Example:

```bash
XRAY_GUI_DEVELOPMENT_TEAM=ABCDE12345 \
XRAY_GUI_PRODUCT_BASE_BUNDLE_IDENTIFIER=dev.example.xraygui \
XRAY_GUI_NOTARY_PROFILE=xraygui-notary \
bash ./scripts/release_macos_app.sh
```

Unsigned smoke packaging is also available for local validation:

```bash
XRAY_GUI_ALLOW_UNSIGNED=1 bash ./scripts/release_macos_app.sh
```

The release output directory will contain:

- `xray_gui.app`
- `xray_gui-macos.zip`
- `xray_gui-macos.dmg`

## Runtime Updates

The native SwiftUI workspace now shows:

- current effective Xray version and source;
- latest stable Xray release from `XTLS/Xray-core`;
- installed and latest GeoData release tags from `Loyalsoldier/v2ray-rules-dat`;
- buttons to update the kernel and GeoData without modifying the signed app bundle.
