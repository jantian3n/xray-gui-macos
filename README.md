# Xray Native for macOS

This repository now keeps only the Swift native migration track.

## Current Layout

- `native/`
  - Swift Package entry
  - shared core models and config compiler
  - macOS desktop runtime
  - SwiftUI macOS app
- `assets/`
  - bundled `xray` runtime for macOS
  - bootstrap geodata

## Build

```bash
cd native
swift build
swift test
```

## Run

```bash
cd native
swift run XrayNativeMacApp
```

## Package Local `.app`

```bash
native/scripts/package_macos_app.sh
```

Artifact:

- `native/dist/XrayNativeMacApp.app`

For more details, see [`native/README.md`](./native/README.md).
