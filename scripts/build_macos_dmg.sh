#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd "${script_dir}/.." && pwd)"
app_name="${APP_NAME:-xray_gui}"
volume_name="${DMG_VOLUME_NAME:-Xray GUI}"
release_dir="${project_dir}/build/macos/Build/Products/Release"
app_path="${release_dir}/${app_name}.app"
dmg_work_dir="${project_dir}/build/macos/dmg"
dmg_root="${dmg_work_dir}/root"
dmg_path="${dmg_work_dir}/${app_name}.dmg"
zip_path="${dmg_work_dir}/${app_name}.zip"
sign_identity="${APPLE_SIGN_IDENTITY:-}"
notary_profile="${APPLE_NOTARY_PROFILE:-}"

mkdir -p "${dmg_work_dir}"

if [[ ! -x "${project_dir}/assets/bin/macos/xray" ]]; then
  echo "Bundled macOS xray binary not found. Building it first..."
  bash "${project_dir}/scripts/build_desktop_xray.sh" macos
fi

echo "Running Flutter release build..."
(
  cd "${project_dir}"
  flutter pub get
  flutter build macos --release
)

if [[ ! -d "${app_path}" ]]; then
  echo "Expected app bundle was not produced: ${app_path}" >&2
  exit 1
fi

if [[ -n "${sign_identity}" ]]; then
  echo "Signing app bundle with: ${sign_identity}"
  codesign \
    --force \
    --deep \
    --options runtime \
    --timestamp \
    --sign "${sign_identity}" \
    "${app_path}"
  codesign --verify --deep --strict --verbose=2 "${app_path}"
else
  cat <<'EOF'
WARNING:
  APPLE_SIGN_IDENTITY is not set, so the .app and .dmg will stay unsigned.
  On another Mac, a DMG downloaded from the internet is very likely to be
  blocked by Gatekeeper and shown as "damaged".
EOF
fi

if [[ -n "${sign_identity}" && -n "${notary_profile}" ]]; then
  echo "Submitting signed app bundle for notarization with profile: ${notary_profile}"
  rm -f "${zip_path}"
  ditto -c -k --keepParent "${app_path}" "${zip_path}"
  xcrun notarytool submit "${zip_path}" \
    --keychain-profile "${notary_profile}" \
    --wait
  xcrun stapler staple "${app_path}"
fi

rm -rf "${dmg_root}"
mkdir -p "${dmg_root}"
cp -R "${app_path}" "${dmg_root}/"
ln -sfn /Applications "${dmg_root}/Applications"

rm -f "${dmg_path}"
echo "Creating DMG: ${dmg_path}"
hdiutil create \
  -volname "${volume_name}" \
  -srcfolder "${dmg_root}" \
  -ov \
  -format UDZO \
  "${dmg_path}"

if [[ -n "${sign_identity}" ]]; then
  echo "Signing DMG..."
  codesign --force --timestamp --sign "${sign_identity}" "${dmg_path}"
fi

if [[ -n "${sign_identity}" && -n "${notary_profile}" ]]; then
  echo "Submitting DMG for notarization..."
  xcrun notarytool submit "${dmg_path}" \
    --keychain-profile "${notary_profile}" \
    --wait
  xcrun stapler staple "${dmg_path}"
fi

if command -v spctl >/dev/null 2>&1 && [[ -n "${sign_identity}" ]]; then
  echo "Gatekeeper assessment for app bundle:"
  spctl -a -vv "${app_path}" || true
fi

cat <<EOF
Done.
App: ${app_path}
DMG: ${dmg_path}
EOF
