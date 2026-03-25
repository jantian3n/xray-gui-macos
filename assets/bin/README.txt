Place desktop Xray binaries here before packaging the Flutter app.

- macOS: assets/bin/macos/xray
- Windows: assets/bin/windows/xray.exe

You can generate them from the repo root with:

  bash ./gui/xray_gui/scripts/build_desktop_xray.sh macos
  bash ./gui/xray_gui/scripts/build_desktop_xray.sh windows amd64
