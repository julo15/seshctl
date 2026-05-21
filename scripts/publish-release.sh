#!/usr/bin/env bash
# Stage 2 of `make publish`: publish the DMG to GitHub Releases.
#
# Re-runnable when the first attempt fails partway (e.g. network blip during
# asset upload). If the release already exists, this refuses with a hint —
# either delete + retry (`gh release delete v<VERSION>`) or add the missing
# asset directly (`gh release upload v<VERSION> dist/Seshctl-<VERSION>.dmg`).
#
# Inputs:
#   - Resources/Info.plist       (CFBundleShortVersionString — source of truth)
#   - dist/Seshctl-<VERSION>.dmg (produced by `make dist`)
#   - docs/release-notes/<VERSION>.md (used as the release body)
#
# Side effects:
#   - Creates GitHub Release v<VERSION> with the DMG attached.
#   - Creates the v<VERSION> git tag on the remote (via gh release create).

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_DIR="$( cd "${SCRIPT_DIR}/.." && pwd )"
cd "${REPO_DIR}"

VERSION="$(plutil -extract CFBundleShortVersionString raw -o - Resources/Info.plist)"
if [[ -z "${VERSION}" ]]; then
  echo "Error: could not read CFBundleShortVersionString from Resources/Info.plist" >&2
  exit 1
fi

DMG_PATH="dist/Seshctl-${VERSION}.dmg"
NOTES_PATH="docs/release-notes/${VERSION}.md"

echo "==> Publish release for v${VERSION}"

# --- Pre-flight checks ---

# 1. DMG + release notes must exist.
if [[ ! -f "${DMG_PATH}" ]]; then
  echo "Error: ${DMG_PATH} not found. Run \`make dist\` first." >&2
  exit 1
fi
if [[ ! -f "${NOTES_PATH}" ]]; then
  echo "Error: ${NOTES_PATH} not found. Write the release notes before publishing." >&2
  exit 1
fi

# 2. `gh` is authenticated.
if ! gh auth status >/dev/null 2>&1; then
  echo "Error: \`gh auth status\` failed. Run \`gh auth login\` first." >&2
  exit 1
fi

# 3. Release must not already exist. gh exits 1 with "release not found" when
#    the release doesn't exist — that's the success case for us.
if gh release view "v${VERSION}" >/dev/null 2>&1; then
  echo "Error: GitHub Release v${VERSION} already exists." >&2
  echo "       Either confirm it's complete (check assets at gh release view v${VERSION})," >&2
  echo "       or delete + retry: gh release delete v${VERSION} --cleanup-tag --yes" >&2
  echo "       Add a missing asset only: gh release upload v${VERSION} ${DMG_PATH}" >&2
  exit 1
fi

echo "==> Pre-flight checks passed."

# --- Create the release ---

echo "==> gh release create v${VERSION} ..."
gh release create "v${VERSION}" \
  "${DMG_PATH}" \
  --title "Seshctl ${VERSION}" \
  --notes-file "${NOTES_PATH}"

echo ""
echo "==> Release URL:"
gh release view "v${VERSION}" --json url -q .url
