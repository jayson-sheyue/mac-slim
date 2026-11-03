#!/bin/zsh
# One release artifact: upload -> download/verify -> install/verify -> publish.
set -euo pipefail
SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
cd "${PROJECT_DIR}"
REPO="jayson-sheyue/mac-slim"
VERSION="$(tr -d '[:space:]' < VERSION)"
TAG="v${VERSION}"
COMMIT="$(git rev-parse HEAD)"
NOTES="${PROJECT_DIR}/docs/release-notes.md"
MODE="${1:---prerelease}"
if [[ "${MODE}" != "--prerelease" && "${MODE}" != "--stable" ]]; then
    print -u2 "Usage: ./scripts/publish_release.sh [--prerelease|--stable]"; exit 2
fi
if [[ "${MODE}" == "--stable" && "${VERSION}" == *-* ]]; then
    print -u2 "A prerelease version cannot be published as stable"; exit 1
fi
[[ -z "$(git status --porcelain)" ]] || { print -u2 "Commit the exact release source before publishing"; exit 1; }
[[ "$(git rev-parse origin/main)" == "${COMMIT}" ]] || { print -u2 "Push the release source to origin/main first"; exit 1; }
REMOTE_COMMIT="$(git ls-remote origin refs/heads/main | awk '{print $1}')"
[[ "${REMOTE_COMMIT}" == "${COMMIT}" ]] || { print -u2 "Remote main changed; inspect it before releasing"; exit 1; }
# Require a successful CI run for this exact commit; never infer success from another revision.
CI_RUNS="$(gh run list -R "${REPO}" --commit "${COMMIT}" --workflow ci.yml --json status,conclusion --limit 10)"
CI_RUNS_JSON="${CI_RUNS}" python3 - <<'PY'
import json, os
runs=json.loads(os.environ['CI_RUNS_JSON'])
if not any(run['status']=='completed' and run['conclusion']=='success' for run in runs):
    raise SystemExit('Exact-commit CI has not passed; release not created')
PY
RESUME=false
if gh release view "${TAG}" -R "${REPO}" >/dev/null 2>&1; then
    [[ "$(gh release view "${TAG}" -R "${REPO}" --json isDraft --jq '.isDraft')" == "true" ]] || { print -u2 "Published releases are immutable; choose a new version"; exit 1; }
    RESUME=true
    print "Resuming the existing draft assets without rebuilding"
fi
if [[ "${RESUME}" == false ]]; then ./scripts/build_dmg.sh; fi
WORK="$(mktemp -d "${TMPDIR:-/tmp}/macslim-publish.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT
/usr/bin/swiftc -swift-version 6 -warnings-as-errors -module-cache-path "${PROJECT_DIR}/.build/module-cache" -target "$(uname -m)-apple-macosx13.0" -parse-as-library scripts/app_lifecycle.swift -o "${WORK}/app_lifecycle"
RELEASE_FLAGS=(--draft --target "${COMMIT}" --title "MacSlim ${VERSION}" --notes-file "${NOTES}")
if [[ "${MODE}" == "--prerelease" ]]; then RELEASE_FLAGS+=(--prerelease --latest=false); fi
if [[ "${RESUME}" == false ]]; then
gh release create "${TAG}" -R "${REPO}" "${RELEASE_FLAGS[@]}" \
    "dist/MacSlim-${VERSION}-Universal.dmg" dist/SHA256SUMS.txt dist/release-manifest.json
fi
# Install the bytes fetched back from GitHub, never a separately rebuilt app.
gh release download "${TAG}" -R "${REPO}" --dir "${WORK}/download" \
    --pattern "MacSlim-${VERSION}-Universal.dmg" --pattern SHA256SUMS.txt --pattern release-manifest.json
(cd "${WORK}/download" && /usr/bin/shasum -a 256 -c SHA256SUMS.txt)
if [[ "${RESUME}" == false ]]; then
    /usr/bin/cmp "dist/MacSlim-${VERSION}-Universal.dmg" "${WORK}/download/MacSlim-${VERSION}-Universal.dmg"
fi
[[ "$(/usr/bin/plutil -extract sourceCommit raw -o - "${WORK}/download/release-manifest.json")" == "${COMMIT}" ]] || { print -u2 "Draft source commit differs; refusing to install or publish"; exit 1; }
python3 scripts/local_install.py install --dmg "${WORK}/download/MacSlim-${VERSION}-Universal.dmg" \
    --manifest "${WORK}/download/release-manifest.json" --helper "${WORK}/app_lifecycle" --receipt dist/local-installation.json
python3 scripts/local_install.py verify --dmg "${WORK}/download/MacSlim-${VERSION}-Universal.dmg" \
    --manifest "${WORK}/download/release-manifest.json" --installed
# Only the complete, locally verified draft becomes public.
gh release edit "${TAG}" -R "${REPO}" --draft=false
# Read the public release again and verify the published artifact against the running installation.
gh release download "${TAG}" -R "${REPO}" --dir "${WORK}/published" \
    --pattern "MacSlim-${VERSION}-Universal.dmg" --pattern release-manifest.json
python3 scripts/local_install.py verify --dmg "${WORK}/published/MacSlim-${VERSION}-Universal.dmg" \
    --manifest "${WORK}/published/release-manifest.json" --installed
gh release view "${TAG}" -R "${REPO}" --json url,isDraft,isPrerelease,tagName
print "Installed and running: /Applications/MacSlim.app (${VERSION})"
