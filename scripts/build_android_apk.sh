#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
project_dir="$(cd "${script_dir}/.." && pwd)"

if [ -f "${HOME}/.zprofile" ]; then
  # shellcheck source=/dev/null
  source "${HOME}/.zprofile"
fi

# Local proxy settings can corrupt Gradle/SDK HTTPS downloads in some environments.
unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY

cd "${project_dir}"

has_target_platform="false"
for arg in "$@"; do
  if [ "${arg}" = "--target-platform" ] || [[ "${arg}" == --target-platform=* ]]; then
    has_target_platform="true"
    break
  fi
done

if [ "${has_target_platform}" = "true" ]; then
  flutter build apk "$@"
else
  flutter build apk --target-platform android-arm64 "$@"
fi

output_dir="${project_dir}/build/app/outputs/flutter-apk"

if [ -d "${output_dir}" ]; then
  for apk_path in "${output_dir}"/app-*.apk; do
    if [ -f "${apk_path}" ]; then
      renamed_path="${output_dir}/note-${apk_path##*/app-}"
      mv -f "${apk_path}" "${renamed_path}"
      printf 'Renamed APK to %s\n' "${renamed_path}"
    fi
  done
fi
