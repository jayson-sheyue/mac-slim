#!/bin/zsh
set -euo pipefail
SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
VERSION="$(tr -d '[:space:]' < "${PROJECT_DIR}/VERSION")"
BINARY="${PROJECT_DIR}/dist/MacSlim.app/Contents/MacOS/MacSlim"
/usr/bin/lipo "${BINARY}" -verify_arch arm64 x86_64
/usr/bin/codesign --verify --deep --strict --verbose=2 "${PROJECT_DIR}/dist/MacSlim.app"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${PROJECT_DIR}/dist/MacSlim.app/Contents/Info.plist")" == "${VERSION}" ]]
"${BINARY}" --self-check
[[ "$(/usr/bin/plutil -extract version raw -o - "${PROJECT_DIR}/dist/release-manifest.json")" == "${VERSION}" ]]
[[ "$(/usr/bin/plutil -extract buildNumber raw -o - "${PROJECT_DIR}/dist/release-manifest.json")" == "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${PROJECT_DIR}/dist/MacSlim.app/Contents/Info.plist")" ]]
# Checksums list names relative to dist, not the repository root.
(cd "${PROJECT_DIR}/dist" && /usr/bin/shasum -a 256 -c SHA256SUMS.txt)
/usr/bin/hdiutil verify "${PROJECT_DIR}/dist/MacSlim-${VERSION}-Universal.dmg"
if [[ -n "${GITHUB_REF_NAME:-}" && "${GITHUB_REF_TYPE:-}" == "tag" ]]; then
    [[ "${GITHUB_REF_NAME}" == "v${VERSION}" ]] || { print -u2 "Tag/version mismatch"; exit 1; }
fi
