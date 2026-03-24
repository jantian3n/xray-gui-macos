# Xray GUI macOS

Native macOS rewrite of the Android-first Xray GUI project.

## Current Direction

This repo is now moving toward a full `Swift + SwiftUI + AppKit + NetworkExtension` stack.

What is already in place:

- the macOS app entry point is native Swift, not a Flutter window anymore;
- the current window and menu are hosted by SwiftUI/AppKit;
- a first Swift implementation now parses `vless://` links and script-style outbound JSON;
- a first Swift implementation now compiles Xray JSON for macOS proxy modes;
- the old Flutter/Dart code is still kept in the repo as migration reference.

What is not fully migrated yet:

- profile persistence and subscriptions;
- native `xray` process lifecycle and log streaming;
- native system-proxy management wiring;
- Packet Tunnel / NetworkExtension for TUN-style routing.

## Quick Start

1. Install full Xcode on macOS.
2. Open `macos/Runner.xcodeproj` in Xcode.
3. Run the `Runner` target.

The repository still contains:

- `assets/bin/macos/xray` for bundled runtime experiments;
- `lib/` as the legacy Flutter reference implementation;
- `scripts/` from the earlier migration stage.

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
- generate a pretty-printed Xray JSON preview through Swift logic.

This is the foundation for the next migration steps.

## Next Work

- move profile storage and subscription import to Swift;
- move runtime process management and proxy control to Swift;
- add NetworkExtension Packet Tunnel support;
- finish signing, packaging, and distribution for a real macOS `.app`.
