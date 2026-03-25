# Xray GUI macOS Host

This directory contains the Flutter macOS host and the macOS-specific desktop
behavior for the Xray GUI app.

## Current Behavior

- local proxy mode only, with automatic macOS system proxy switching on connect;
- window close hides the app instead of exiting, so the app can keep running in
  the menu bar;
- desktop UI uses a sidebar + toolbar layout instead of reusing the mobile
  bottom navigation shell;
- node editing opens in a desktop dialog instead of a bottom sheet;
- left click on the menu bar icon opens the main window;
- right click on the menu bar icon shows:
  - `打开软件`
  - `切换节点` when more than one node exists
  - `退出软件`
- switching nodes from the menu bar restarts the desktop runtime when Xray is
  already running;
- upload/download speed shown in the menu bar comes from Xray's own
  `StatsService` counters, not from a guessed network interface sample.
- connecting in local proxy mode now also enables macOS Web/Secure Web/SOCKS
  system proxy for the active network service and restores the previous
  settings when the runtime stops.

## Key Files

- `../lib/main.dart`
  Initializes `window_manager` before the Flutter app starts.
- `Runner/AppDelegate.swift`
  Keeps the app alive after the last window closes and restores hidden windows
  when the Dock icon is clicked again.
- `../lib/src/core/services/macos_status_bar_controller.dart`
  Owns the menu bar icon, right-click menu, window hide/show flow, and rate
  formatting.
- `../lib/src/core/services/desktop_runtime_bridge.dart`
  Injects the local Xray `StatsService` API config and polls traffic counters
  for the menu bar.
- `../scripts/build_macos_dmg.sh`
  Builds the release app bundle and packages it as a DMG. It can also sign and
  notarize when Apple credentials are available.

## Local Development

From `gui/xray_gui/`:

```bash
flutter pub get
flutter run -d macos
```

Useful checks:

```bash
flutter analyze
flutter build macos --debug
```

If desktop plugins fail to build, first make sure CocoaPods is installed and
`pod --version` works in your shell.

## Troubleshooting

### App says the Xray executable cannot be found

The macOS build must contain:

```text
App.framework/Versions/A/Resources/flutter_assets/assets/bin/macos/xray
```

This project now declares the binary explicitly in `pubspec.yaml`, so rebuild
the app or DMG after updating assets:

```bash
flutter pub get
flutter build macos --release
```

You can also temporarily override the bundled runtime with:

```bash
export XRAY_GUI_XRAY_BINARY=/absolute/path/to/xray
```

### `failed to create server socket ... Operation not permitted`

The release app binds several loopback ports on `127.0.0.1`:

- the local SOCKS proxy;
- the local HTTP proxy;
- the injected Xray `StatsService` API endpoint used by the macOS menu bar.

If the release build is sandboxed but missing the right entitlements, macOS
will block those bind calls and Dart will surface an error like:

```text
failed to create server socket os error operation not permitted errno = 1
```

Keep these keys in `Runner/Release.entitlements`:

```xml
<key>com.apple.security.network.client</key>
<true/>
<key>com.apple.security.network.server</key>
<true/>
```

After changing entitlements, rebuild the release app or DMG:

```bash
flutter build macos --release
bash ./scripts/build_macos_dmg.sh
```

## DMG Packaging

From the repository root:

```bash
bash ./gui/xray_gui/scripts/build_macos_dmg.sh
```

Artifacts:

- app bundle:
  `gui/xray_gui/build/macos/Build/Products/Release/xray_gui.app`
- dmg:
  `gui/xray_gui/build/macos/dmg/xray_gui.dmg`

Unsigned DMGs are fine for local testing, but macOS Gatekeeper will often mark
them as "damaged" after download on another machine. For a distributable build,
set:

- `APPLE_SIGN_IDENTITY`
- `APPLE_NOTARY_PROFILE`

Then rerun:

```bash
bash ./gui/xray_gui/scripts/build_macos_dmg.sh
```

Also replace the placeholder bundle identifier in
`Runner/Configs/AppInfo.xcconfig` before publishing.
