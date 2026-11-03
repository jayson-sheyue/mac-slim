#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
VERSION="$(tr -d '[:space:]' < "${PROJECT_DIR}/VERSION")"
BUILD_NUMBER="100"
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
  "channel": "stable",
  "publishedAt": "${PUB_DATE}",
  "minSystemVersion": "13.0",
  "supportedArchitectures": [
    "arm64",
    "x86_64"
  ],
  "dmgUrl": "https://github.com/${REPO_SLUG}/releases/download/v${VERSION}/${DMG_NAME}",
  "sha256": "${SHA256_HASH}",
  "sizeBytes": ${SIZE_BYTES},
  "releaseNotes": "MacSlim v${VERSION} 正式发布：支持 6 大无损清理规则（Electron ShipIt/Sparkle 更新残留、Chrome 多版本冗余内核、Service Worker 离线缓存、日志与开发缓存、Cursor state.vscdb 原子无损重组、长期休眠应用识别），内置废纸篓回退保护与应用内 SHA-256 完整性校验更新。"
}
EOF

echo "==> Generated SHA256SUMS.txt and release-manifest.json:"
cat "${DIST_DIR}/SHA256SUMS.txt"
