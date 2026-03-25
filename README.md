# Xray GUI

Android-first Flutter shell for an Xray-based GUI client.

## Current Status

This directory contains the initial app structure for:

- `vless://` parsing;
- script-style `client_outbound.json` import;
- `client_split_patch.json` application for split XHTTP modes;
- typed profile models;
- Xray JSON compilation for Android VPN mode or local proxy mode, including
  `xhttpSettings.downloadSettings` and TLS/REALITY variants;
- method channel contracts for the Android runtime bridge;
- a starter home screen for import, preview, and runtime actions.

The Android runtime template is now present and a generated Flutter Android host can be built into a debug APK.
The current APK is still a dry-run shell until a real `xraymobile.aar` is built and installed.

The macOS desktop host is now wired in as well, including:

- local proxy runtime startup for desktop;
- a menu bar icon with open / switch node / quit actions;
- live upload and download speed in the macOS status bar;
- a DMG packaging helper for later release work.

## Planned Runtime Flow

1. Flutter parses a `vless://` link.
2. Flutter compiles a profile into Xray JSON.
3. Flutter sends the config to Android.
4. Android starts `VpnService`.
5. Android passes the TUN fd into the embedded Xray runtime.
6. Logs stream back to Flutter through an event channel.

## Directory Layout

```text
lib/
  main.dart
  src/
    app.dart
    core/
      models/
      services/
    features/
      home/
```

## Android Native Template

Native Android files currently live in:

```text
android_template/
```

This is intentional. Once Flutter is available, generate the Android host with:

```bash
flutter create --platforms android .
```

Then merge:

```text
android_template/app/src/main/... -> android/app/src/main/...
```

Or use:

```bash
bash ./scripts/merge_android_template.sh
```

## Native Android Work To Add Next

- build and install `xraymobile.aar`;
- replace dry-run VPN mode with the real embedded runtime path;
- verify real traffic forwarding on device.

## Debugging

See [`docs/android-debugging.md`](../../docs/android-debugging.md) for the full run and debug workflow.

## Build On macOS

See [`docs/android-build-macos.md`](../../docs/android-build-macos.md) for the end-to-end macOS build path, including:

- Flutter Android host generation
- gomobile AAR build
- AAR import into the Android app
- APK build commands
- the proxy-safe helper script `scripts/build_android_apk.sh`

For the macOS desktop host itself, see [`macos/README.md`](./macos/README.md)
and [`docs/desktop-build.md`](../../docs/desktop-build.md).
