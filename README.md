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
- the old Flutter/Dart code is still kept in the repo as migration reference.

What is not fully migrated yet:

- subscriptions and richer profile editing;
- deeper runtime validation and production packaging polish;
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
- save imported nodes into native local storage;
- generate a pretty-printed Xray JSON preview through Swift logic;
- start and stop a native `xray` runtime flow;
- show runtime logs inside the native UI.

This is the foundation for the next migration steps.

## Next Work

- move subscription import and richer profile management to Swift;
- harden runtime behavior, startup validation, and recovery UX;
- add NetworkExtension Packet Tunnel support;
- finish signing, packaging, and distribution for a real macOS `.app`.
