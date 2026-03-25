#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
OUT_DIR="${REPO_ROOT}/build"
ANDROID_API="${ANDROID_API:-24}"
ANDROID_TARGETS="${ANDROID_TARGETS:-android/arm64}"

mkdir -p "${OUT_DIR}"

cd "${REPO_ROOT}"

echo "Building xraymobile.aar with Android API ${ANDROID_API} for ${ANDROID_TARGETS}"
gomobile bind \
  -target="${ANDROID_TARGETS}" \
  -androidapi "${ANDROID_API}" \
  -o "${OUT_DIR}/xraymobile.aar" \
  ./mobile/xraymobile

echo "Output: ${OUT_DIR}/xraymobile.aar"
