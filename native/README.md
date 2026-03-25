# Xray Native

This directory is the native Swift migration track for the Flutter-based Xray GUI.

## What is here

- `XrayNativeCore`
  - shared domain models
  - `vless://` parsing
  - `client_outbound.json` import
  - split patch application
  - Xray JSON compilation
  - local JSON persistence
- `XrayNativeDesktopRuntime`
  - local `xray` process startup
  - macOS system proxy switching
  - geodata update
  - traffic polling through Xray `StatsService`
- `XrayNativeMacApp`
  - native SwiftUI macOS shell
  - `MenuBarExtra`
  - node import / selection / delete
  - config preview
  - runtime logs

## Why this layout

The goal is to keep the shared protocol and config logic independent from the macOS shell, so the next iOS app can reuse `XrayNativeCore` directly and add an iOS-specific runtime host later.

## Run locally

From the repository root:

```bash
cd native
swift build
swift test
swift run XrayNativeMacApp
```

## Runtime assets

The native macOS runtime currently reuses the existing repository assets:

- `../assets/bin/macos/xray`
- `../assets/bootstrap-geodata/*.dat`

You can also override the runtime binary with:

```bash
export XRAY_GUI_XRAY_BINARY=/absolute/path/to/xray
```

## Current gaps

- no native node form editor yet; import is text-first for now
- no macOS packaging project yet; the current entry is SwiftPM-based
- no iOS host target yet; the architecture is prepared, but the runtime host still needs to be added
