#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEMPLATE_DIR="${APP_ROOT}/android_template/app/src/main"
ANDROID_MAIN_DIR="${APP_ROOT}/android/app/src/main"

if [[ ! -d "${ANDROID_MAIN_DIR}" ]]; then
  echo "Android host not found at ${ANDROID_MAIN_DIR}"
  echo "Run: flutter create --platforms android ."
  exit 1
fi

rsync -a "${TEMPLATE_DIR}/" "${ANDROID_MAIN_DIR}/"
echo "Merged android_template into android/app/src/main"
