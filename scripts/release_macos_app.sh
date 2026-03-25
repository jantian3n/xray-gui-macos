#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
project_path="${repo_root}/macos/Runner.xcodeproj"
scheme="Runner"
configuration="${XRAY_GUI_CONFIGURATION:-Release}"
app_name="xray_gui.app"
archive_path="${XRAY_GUI_ARCHIVE_PATH:-${repo_root}/build/macos/archive/${scheme}.xcarchive}"
export_dir="${XRAY_GUI_EXPORT_DIR:-${repo_root}/build/macos/release}"
zip_path="${XRAY_GUI_ZIP_PATH:-${export_dir}/xray_gui-macos.zip}"
dmg_path="${XRAY_GUI_DMG_PATH:-${export_dir}/xray_gui-macos.dmg}"
dmg_volume_name="${XRAY_GUI_DMG_VOLUME_NAME:-Xray GUI macOS}"
allow_unsigned="${XRAY_GUI_ALLOW_UNSIGNED:-0}"
team_id="${XRAY_GUI_DEVELOPMENT_TEAM:-}"
sign_identity="${XRAY_GUI_CODE_SIGN_IDENTITY:-Developer ID Application}"
notary_profile="${XRAY_GUI_NOTARY_PROFILE:-}"
allow_provisioning_updates="${XRAY_GUI_ALLOW_PROVISIONING_UPDATES:-0}"
app_info_xcconfig="${repo_root}/macos/Runner/Configs/AppInfo.xcconfig"

trim() {
  local value="${1:-}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "${value}"
}

create_distribution_dmg() {
  local source_app="${1:?missing app path}"
  local output_dmg="${2:?missing dmg path}"
  local volume_name="${3:?missing volume name}"
  local staging_dir
  local app_basename

  staging_dir="$(mktemp -d "${TMPDIR:-/tmp}/xray-gui-dmg.XXXXXX")"
  app_basename="$(basename "${source_app}")"

  rm -f "${output_dmg}"
  ditto "${source_app}" "${staging_dir}/${app_basename}"
  ln -s /Applications "${staging_dir}/Applications"

  hdiutil create \
    -volname "${volume_name}" \
    -srcfolder "${staging_dir}" \
    -fs HFS+ \
    -format UDZO \
    -ov \
    "${output_dmg}" >/dev/null

  rm -rf "${staging_dir}"
}

read_xcconfig_value() {
  local key="${1:?missing xcconfig key}"
  awk -F '=' -v key="${key}" '
    $1 ~ "^[[:space:]]*" key "[[:space:]]*$" {
      value = $2
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      print value
    }
  ' "${app_info_xcconfig}" | tail -n 1
}

configured_base_bundle_id="$(trim "$(read_xcconfig_value PRODUCT_BASE_BUNDLE_IDENTIFIER)")"
base_bundle_id="${XRAY_GUI_PRODUCT_BASE_BUNDLE_IDENTIFIER:-${configured_base_bundle_id}}"
base_bundle_id="$(trim "${base_bundle_id}")"

if [[ -z "${base_bundle_id}" ]]; then
  echo "Unable to resolve PRODUCT_BASE_BUNDLE_IDENTIFIER." >&2
  exit 1
fi

if [[ "${allow_unsigned}" != "1" && -z "${team_id}" ]]; then
  cat >&2 <<'EOF'
XRAY_GUI_DEVELOPMENT_TEAM is required for a signed archive.
If you only want to smoke-test packaging, rerun with:
  XRAY_GUI_ALLOW_UNSIGNED=1 bash ./scripts/release_macos_app.sh
EOF
  exit 1
fi

if [[ "${allow_unsigned}" != "1" && "${base_bundle_id}" == com.example.* ]]; then
  cat >&2 <<EOF
The current base bundle identifier is still a placeholder:
  ${base_bundle_id}

Set XRAY_GUI_PRODUCT_BASE_BUNDLE_IDENTIFIER to your own bundle id before signing.
EOF
  exit 1
fi

rm -rf "${archive_path}" "${export_dir}"
mkdir -p "${export_dir}"

xcode_args=(
  xcodebuild
  -project "${project_path}"
  -scheme "${scheme}"
  -configuration "${configuration}"
  -archivePath "${archive_path}"
  archive
  PRODUCT_BASE_BUNDLE_IDENTIFIER="${base_bundle_id}"
  PRODUCT_BUNDLE_IDENTIFIER="${base_bundle_id}"
  PACKET_TUNNEL_BUNDLE_IDENTIFIER="${base_bundle_id}.PacketTunnel"
  ARCHS=arm64
  ONLY_ACTIVE_ARCH=YES
  EXCLUDED_ARCHS=x86_64
  ENABLE_HARDENED_RUNTIME=YES
)

if [[ "${allow_unsigned}" == "1" ]]; then
  xcode_args+=(
    CODE_SIGNING_ALLOWED=NO
    CODE_SIGNING_REQUIRED=NO
  )
else
  xcode_args+=(
    CODE_SIGN_STYLE=Automatic
    DEVELOPMENT_TEAM="${team_id}"
    CODE_SIGN_IDENTITY="${sign_identity}"
  )
fi

if [[ "${allow_provisioning_updates}" == "1" ]]; then
  xcode_args+=(-allowProvisioningUpdates)
fi

echo "Archiving ${scheme} (${configuration})"
"${xcode_args[@]}"

app_path="${archive_path}/Products/Applications/${app_name}"
if [[ ! -d "${app_path}" ]]; then
  echo "Archived app not found at ${app_path}" >&2
  exit 1
fi

cp -R "${app_path}" "${export_dir}/"
packaged_app_path="${export_dir}/${app_name}"

if [[ "${allow_unsigned}" != "1" ]]; then
  echo "Verifying code signature"
  codesign --verify --deep --strict --verbose=2 "${packaged_app_path}"
fi

echo "Creating zip archive"
rm -f "${zip_path}"
ditto -c -k --keepParent "${packaged_app_path}" "${zip_path}"

if [[ -n "${notary_profile}" ]]; then
  if [[ "${allow_unsigned}" == "1" ]]; then
    echo "XRAY_GUI_NOTARY_PROFILE cannot be used with XRAY_GUI_ALLOW_UNSIGNED=1" >&2
    exit 1
  fi

  echo "Submitting zip to notary service"
  xcrun notarytool submit "${zip_path}" --keychain-profile "${notary_profile}" --wait

  echo "Stapling notarization ticket"
  xcrun stapler staple "${packaged_app_path}"
  codesign --verify --deep --strict --verbose=2 "${packaged_app_path}"

  echo "Repacking stapled app"
  rm -f "${zip_path}"
  ditto -c -k --keepParent "${packaged_app_path}" "${zip_path}"
fi

echo "Creating dmg archive"
create_distribution_dmg "${packaged_app_path}" "${dmg_path}" "${dmg_volume_name}"

if [[ -n "${notary_profile}" ]]; then
  echo "Submitting dmg to notary service"
  xcrun notarytool submit "${dmg_path}" --keychain-profile "${notary_profile}" --wait

  echo "Stapling dmg notarization ticket"
  xcrun stapler staple "${dmg_path}"
fi

cat <<EOF
Release artifacts:
  app: ${packaged_app_path}
  zip: ${zip_path}
  dmg: ${dmg_path}
  bundle id: ${base_bundle_id}
EOF
