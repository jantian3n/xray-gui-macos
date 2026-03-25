#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_DIR="$(cd "$ROOT_DIR/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build/arm64-apple-macosx/release"
PRODUCT_NAME="XrayNativeMacApp"
APP_NAME="$PRODUCT_NAME.app"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
BIN_DIR="$RESOURCES_DIR/bin"
GEODATA_DIR="$RESOURCES_DIR/geodata"
INFO_PLIST="$CONTENTS_DIR/Info.plist"
EXECUTABLE_PATH="$BUILD_DIR/$PRODUCT_NAME"
XRAY_BINARY_PATH="$REPO_DIR/assets/bin/macos/xray"
GEODATA_SOURCE_DIR="$REPO_DIR/assets/bootstrap-geodata"

mkdir -p "$DIST_DIR"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$BIN_DIR" "$GEODATA_DIR"

cp "$EXECUTABLE_PATH" "$MACOS_DIR/$PRODUCT_NAME"
chmod 755 "$MACOS_DIR/$PRODUCT_NAME"
cp "$XRAY_BINARY_PATH" "$BIN_DIR/xray"
chmod 755 "$BIN_DIR/xray"
cp "$GEODATA_SOURCE_DIR"/geoip.dat "$GEODATA_DIR/geoip.dat"
cp "$GEODATA_SOURCE_DIR"/geosite.dat "$GEODATA_DIR/geosite.dat"

cat > "$INFO_PLIST" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>XrayNativeMacApp</string>
  <key>CFBundleIdentifier</key>
  <string>dev.xray.native</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>XrayNativeMacApp</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
EOF

codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || true

echo "$APP_DIR"
