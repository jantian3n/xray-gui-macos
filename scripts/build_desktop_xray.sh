#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
assets_root="${repo_root}/assets/bin/macos"

source_binary="${1:-}"
target_binary="${assets_root}/xray"

if [[ -z "${source_binary}" ]]; then
  cat <<'EOF'
Usage:
  bash ./scripts/build_desktop_xray.sh /absolute/path/to/xray
EOF
  exit 1
fi

if [[ ! -f "${source_binary}" ]]; then
  echo "Source binary not found: ${source_binary}" >&2
  exit 1
fi

mkdir -p "${assets_root}"
cp "${source_binary}" "${target_binary}"
chmod +x "${target_binary}"

echo "Bundled macOS xray binary into ${target_binary}"
