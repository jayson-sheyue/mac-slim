#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
VERSION="$(tr -d '[:space:]' < "${PROJECT_DIR}/VERSION")"
BUILD_NUMBER="115"
SOURCE_COMMIT="$(git -C "${PROJECT_DIR}" rev-parse HEAD)"
CHANNEL="stable"
if [[ "${VERSION}" == *-* ]]; then CHANNEL="beta"; fi
DIST_DIR="${PROJECT_DIR}/dist"
DMG_NAME="MacSlim-${VERSION}-Universal.dmg"
DMG_PATH="${DIST_DIR}/${DMG_NAME}"
REPO_SLUG="${GITHUB_REPOSITORY:-jayson-sheyue/mac-slim}"

if [[ ! -f "${DMG_PATH}" ]]; then
    echo "ERROR: Expected DMG at ${DMG_PATH} not found!" >&2
    exit 1
fi

SHA256_HASH="$(/usr/bin/shasum -a 256 "${DMG_PATH}" | awk '{print $1}')"
SIZE_BYTES="$(/usr/bin/stat -f%z "${DMG_PATH}")"
PUB_DATE="$(/bin/date -u +"%Y-%m-%dT%H:%M:%SZ")"

echo "${SHA256_HASH}  ${DMG_NAME}" > "${DIST_DIR}/SHA256SUMS.txt"

cat > "${DIST_DIR}/release-manifest.json" << EOF
{
  "version": "${VERSION}",
  "buildNumber": ${BUILD_NUMBER},
  "channel": "${CHANNEL}",
  "sourceCommit": "${SOURCE_COMMIT}",
  "publishedAt": "${PUB_DATE}",
  "minSystemVersion": "13.0",
  "supportedArchitectures": [
    "arm64",
    "x86_64"
  ],
  "dmgUrl": "https://github.com/${REPO_SLUG}/releases/download/v${VERSION}/${DMG_NAME}",
  "sha256": "${SHA256_HASH}",
  "sizeBytes": ${SIZE_BYTES},
  "releaseNotes": "MacSlim v${VERSION}: Native English, Japanese (日本語), and Simplified Chinese (中文) interface support (defaulting to English on first launch, switchable anytime without resetting scan results); trilingual README documentation; structural detection of update leftovers, caches, and logs with pre-execution verification, Trash recovery, and Playwright reference protection."
}
EOF

echo "==> Generated SHA256SUMS.txt and release-manifest.json:"
cat "${DIST_DIR}/SHA256SUMS.txt"
