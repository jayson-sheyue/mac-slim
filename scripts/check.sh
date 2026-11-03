#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/macslim-check.XXXXXX")"
trap 'rm -rf "${CHECK_DIR}"' EXIT
MODULE_CACHE="${PROJECT_DIR}/.build/module-cache"
TEST_BIN="${CHECK_DIR}/test_runner"

mkdir -p "${MODULE_CACHE}"

echo "==> [Check 1/2] Static typecheck across all Swift sources..."
/usr/bin/swiftc -swift-version 6 -warnings-as-errors -module-cache-path "${MODULE_CACHE}" -typecheck \
    "${PROJECT_DIR}/Sources/Models.swift" \
    "${PROJECT_DIR}/Sources/FileSafety.swift" \
    "${PROJECT_DIR}/Sources/UpdateManager.swift" \
    "${PROJECT_DIR}/Sources/ScannerEngine.swift" \
    "${PROJECT_DIR}/Sources/CleanerEngine.swift" \
    "${PROJECT_DIR}/Sources/TaskCenter.swift" \
    "${PROJECT_DIR}/Sources/MainView.swift" \
    "${PROJECT_DIR}/Sources/MacSlimApp.swift"

echo "==> [Check 2/2] Running isolated unit & integration test suite..."
/usr/bin/swiftc -swift-version 6 -warnings-as-errors -module-cache-path "${MODULE_CACHE}" \
    "${PROJECT_DIR}/Sources/Models.swift" \
    "${PROJECT_DIR}/Sources/FileSafety.swift" \
    "${PROJECT_DIR}/Sources/UpdateManager.swift" \
    "${PROJECT_DIR}/Sources/ScannerEngine.swift" \
    "${PROJECT_DIR}/Sources/CleanerEngine.swift" \
    "${PROJECT_DIR}/Sources/TaskCenter.swift" \
    "${PROJECT_DIR}/Tests/run_tests.swift" \
    -o "${TEST_BIN}"

"${TEST_BIN}"
rm -f "${TEST_BIN}"
echo "==> All fast checks passed!"
