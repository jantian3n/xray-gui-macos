# Xray GUI macOS

macOS-first Flutter shell for an Xray-based GUI client.

## Current Scope

This repository keeps the reusable Flutter UI and a macOS desktop runtime bridge.

Current capabilities:

- import `vless://` links;
- import script-style `client_outbound.json`;
- apply `client_split_patch.json` onto the selected node;
- compile Xray JSON for `localProxy` mode;
- start and stop a local `xray` subprocess on macOS;
- install bundled `geoip.dat` and `geosite.dat`;
- stream runtime logs back into the UI.

The first macOS milestone intentionally focuses on local SOCKS/HTTP proxy mode.
System-level VPN/TUN and automatic system proxy switching are not part of this initial repo setup.

## Quick Start

1. Install Flutter on macOS.
2. Prepare a local `xray` binary and bundle it:

```bash
bash ./scripts/build_desktop_xray.sh /absolute/path/to/xray
```

3. Fetch Flutter dependencies:

```bash
flutter pub get
```

4. Run the app:

```bash
flutter run -d macos
```

You can also skip bundling and point the app at a custom binary at runtime:

```bash
export XRAY_GUI_XRAY_BINARY=/absolute/path/to/xray
flutter run -d macos
```

## Repository Layout

```text
assets/
  bootstrap-geodata/
  bin/
lib/
  main.dart
  src/
macos/
scripts/
test/
```

## Runtime Notes

- Saved profiles are normalized into `localProxy` mode on macOS.
- Default ports remain `127.0.0.1:10808` for SOCKS and `127.0.0.1:10809` for HTTP.
- Geodata updates currently use `Loyalsoldier/v2ray-rules-dat`.

## Next Work

- add macOS system proxy integration;
- evaluate a real TUN path for full-device routing;
- improve packaging, signing, and distribution.
