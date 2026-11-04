#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
VERSION="$(tr -d '[:space:]' < "${PROJECT_DIR}/VERSION")"
BUILD_NUMBER="113"
SOURCE_COMMIT="$(git -C "${PROJECT_DIR}" rev-parse HEAD)"
BUILD_DIR="${PROJECT_DIR}/build"
DIST_DIR="${PROJECT_DIR}/dist"
APP_NAME="MacSlim"
APP_BUNDLE="${DIST_DIR}/${APP_NAME}.app"
DMG_STAGING="${BUILD_DIR}/dmg_staging"
DMG_NAME="${APP_NAME}-${VERSION}-Universal.dmg"
DMG_PATH="${DIST_DIR}/${DMG_NAME}"
MODULE_CACHE="${PROJECT_DIR}/.build/module-cache"
REPO_SLUG="${GITHUB_REPOSITORY:-jayson-sheyue/mac-slim}"

echo "==> [1/6] Running fast checks & automated test suite (v${VERSION})..."
"${PROJECT_DIR}/scripts/check.sh"

# Keep previous runnable build copies recoverable without leaving another .app.
if [[ -d "${APP_BUNDLE}" ]]; then
    PROJECT_ROOT="${PROJECT_DIR}" PYTHONDONTWRITEBYTECODE=1 python3 - <<'ARCHIVE'
import os, sys
from pathlib import Path
root = Path(os.environ['PROJECT_ROOT'])
sys.path.insert(0, str(root / 'scripts'))
from local_install import archive_app
backup = root / '.build/prior-artifacts'
backup.mkdir(parents=True, exist_ok=True)
print(archive_app(root / 'dist/MacSlim.app', backup))
ARCHIVE
fi
rm -rf "${BUILD_DIR}" "${DIST_DIR}"
mkdir -p "${BUILD_DIR}" "${DIST_DIR}" "${MODULE_CACHE}"

echo "==> [2/6] Generating AppIcon.icns..."
ICONSET_DIR="${BUILD_DIR}/AppIcon.iconset"
/usr/bin/swiftc -module-cache-path "${MODULE_CACHE}" \
    "${PROJECT_DIR}/scripts/generate_icon.swift" \
    -o "${BUILD_DIR}/generate_icon"
"${BUILD_DIR}/generate_icon" "${ICONSET_DIR}" "${BUILD_DIR}/AppIcon.icns"

mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"
cp "${BUILD_DIR}/AppIcon.icns" "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"

echo "==> [3/6] Compiling Universal (arm64 + x86_64) native binary..."
SOURCES=(
    "${PROJECT_DIR}/Sources/RuntimeIdentity.swift"
    "${PROJECT_DIR}/Sources/FileSafety.swift"
    "${PROJECT_DIR}/Sources/Models.swift"
    "${PROJECT_DIR}/Sources/UpdateManager.swift"
    "${PROJECT_DIR}/Sources/ScannerEngine.swift"
    "${PROJECT_DIR}/Sources/CleanerEngine.swift"
    "${PROJECT_DIR}/Sources/TaskCenter.swift"
    "${PROJECT_DIR}/Sources/MainView.swift"
    "${PROJECT_DIR}/Sources/MacSlimApp.swift"
)

/usr/bin/swiftc -swift-version 6 -warnings-as-errors -O -module-cache-path "${MODULE_CACHE}" \
    -target arm64-apple-macosx13.0 \
    "${SOURCES[@]}" \
    -o "${BUILD_DIR}/${APP_NAME}_arm64"

/usr/bin/swiftc -swift-version 6 -warnings-as-errors -O -module-cache-path "${MODULE_CACHE}" \
    -target x86_64-apple-macosx13.0 \
    "${SOURCES[@]}" \
    -o "${BUILD_DIR}/${APP_NAME}_x86_64"

/usr/bin/lipo -create -output "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}" \
    "${BUILD_DIR}/${APP_NAME}_arm64" \
    "${BUILD_DIR}/${APP_NAME}_x86_64"

chmod +x "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"

echo "==> [4/6] Writing Info.plist (v${VERSION} build ${BUILD_NUMBER}) and signing bundle..."
cat > "${APP_BUNDLE}/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>MacSlimSourceCommit</key>
    <string>${SOURCE_COMMIT}</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleDisplayName</key>
    <string>MacSlim 瘦身助手</string>
    <key>CFBundleExecutable</key>
    <string>MacSlim</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.macslim.cleaner</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>MacSlim</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 MacSlim. Lightweight Native macOS Storage Cleaner.</string>
</dict>
</plist>
EOF

printf "APPL????" > "${APP_BUNDLE}/Contents/PkgInfo"

/usr/bin/codesign --force --deep --sign - "${APP_BUNDLE}"
/usr/bin/codesign --verify --deep --strict "${APP_BUNDLE}"

echo "==> [5/6] Running binary self-check & version identity verification..."
SELF_CHECK_OUT="$("${APP_BUNDLE}/Contents/MacOS/${APP_NAME}" --self-check)"
echo "${SELF_CHECK_OUT}"
if [[ "${SELF_CHECK_OUT}" != *"v${VERSION}"* ]]; then
    echo "ERROR: Binary version mismatch! Expected v${VERSION} in '${SELF_CHECK_OUT}'" >&2
    exit 1
fi

echo "==> [6/6] Staging DMG folder..."
mkdir -p "${DMG_STAGING}"
cp -R "${APP_BUNDLE}" "${DMG_STAGING}/"
ln -s /Applications "${DMG_STAGING}/Applications"

if [[ "${SKIP_HDIUTIL:-0}" != "1" ]]; then
    /usr/bin/hdiutil create \
        -volname "MacSlim - Mac 瘦身助手" \
        -srcfolder "${DMG_STAGING}" \
        -ov \
        -format UDZO \
        "${DMG_PATH}"
    "${PROJECT_DIR}/scripts/generate_release_metadata.sh"
    "${PROJECT_DIR}/scripts/verify_release.sh"
    rm -rf "${BUILD_DIR}"
    echo "==> Build & Release Metadata Complete!"
    ls -lh "${DIST_DIR}"
fi
