#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
SOURCE_AAR="${REPO_ROOT}/build/xraymobile.aar"
TARGET_DIR="${APP_ROOT}/android/app/libs"

if [[ ! -f "${SOURCE_AAR}" ]]; then
  echo "AAR not found at ${SOURCE_AAR}"
  echo "Run: bash ./gui/xray_gui/scripts/build_android_aar.sh"
  exit 1
fi

mkdir -p "${TARGET_DIR}"
cp "${SOURCE_AAR}" "${TARGET_DIR}/xraymobile.aar"
echo "Installed xraymobile.aar into ${TARGET_DIR}"
