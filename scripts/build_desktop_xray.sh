#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../../.." && pwd)"
assets_root="${repo_root}/gui/xray_gui/assets/bin"

platform="${1:-}"
arch="${2:-}"

if [[ -z "${platform}" ]]; then
  cat <<'EOF'
Usage:
  bash ./gui/xray_gui/scripts/build_desktop_xray.sh macos [arm64|amd64]
  bash ./gui/xray_gui/scripts/build_desktop_xray.sh windows [amd64|arm64]
EOF
  exit 1
fi

case "${platform}" in
  macos)
    goos="darwin"
    goarch="${arch:-$(go env GOARCH)}"
    binary_name="xray"
    output_dir="${assets_root}/macos"
    ;;
  windows)
    goos="windows"
    goarch="${arch:-amd64}"
    binary_name="xray.exe"
    output_dir="${assets_root}/windows"
    ;;
  *)
    echo "Unsupported platform: ${platform}" >&2
    exit 1
    ;;
esac

mkdir -p "${output_dir}"

echo "Building xray for ${goos}/${goarch} -> ${output_dir}/${binary_name}"
(
  cd "${repo_root}"
  GOOS="${goos}" GOARCH="${goarch}" CGO_ENABLED=0 \
    go build -trimpath -o "${output_dir}/${binary_name}" ./main
)

echo "Done."
