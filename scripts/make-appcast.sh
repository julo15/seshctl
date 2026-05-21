#!/usr/bin/env bash
# Sign the current release DMG with EdDSA and regenerate docs/appcast.xml.
#
# Inputs:  dist/Seshctl-<VERSION>.dmg (must exist; build via `make dist`)
#          dist/releases/                  (local DMG mirror — populated here)
#          Resources/Info.plist            (version source of truth)
#          docs/release-notes/<VERSION>.md (optional; embedded into the appcast
#                                           entry's <description> if present)
# Outputs: dist/releases/Seshctl-<VERSION>.dmg            (mirror copy)
#          dist/releases/Seshctl-<VERSION>.html           (rendered notes, if md exists)
#          docs/appcast.xml                               (full appcast, all versions)
#
# Notes:
#   - The private EdDSA key lives in the user's login Keychain
#     (item: `https://sparkle-project.org`, written by `generate_keys`).
#     Both sign_update and generate_appcast pick it up from there.
#   - dist/releases/ is the source of truth for "which versions exist" —
#     generate_appcast walks it and emits one <item> per DMG it finds.
#     Don't manually edit docs/appcast.xml; regenerate via this script.
#   - This script does NOT push or commit. Review the diff, then commit
#     docs/appcast.xml + optionally docs/release-notes/<VERSION>.md, then push.

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_DIR="$( cd "${SCRIPT_DIR}/.." && pwd )"

INFO_PLIST="${REPO_DIR}/Resources/Info.plist"
DIST_DIR="${REPO_DIR}/dist"
RELEASES_DIR="${DIST_DIR}/releases"
DOCS_DIR="${REPO_DIR}/docs"
RELEASE_NOTES_DIR="${DOCS_DIR}/release-notes"

# Sparkle tooling lives inside the resolved SwiftPM artifact dir. We require
# `swift build` to have been run at least once; bail with a clear hint
# otherwise.
SPARKLE_BIN="${REPO_DIR}/.build/artifacts/sparkle/Sparkle/bin"
SIGN_UPDATE="${SPARKLE_BIN}/sign_update"
GENERATE_APPCAST="${SPARKLE_BIN}/generate_appcast"

if [[ ! -x "${SIGN_UPDATE}" || ! -x "${GENERATE_APPCAST}" ]]; then
  echo "Error: Sparkle's sign_update / generate_appcast not found at" >&2
  echo "  ${SPARKLE_BIN}" >&2
  echo "Run \`swift build\` first to fetch the Sparkle artifact." >&2
  exit 1
fi

# Read version from Info.plist (single source of truth).
VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "${INFO_PLIST}")"
if [[ -z "${VERSION}" ]]; then
  echo "Error: could not read CFBundleShortVersionString from ${INFO_PLIST}" >&2
  exit 1
fi

DMG_PATH="${DIST_DIR}/Seshctl-${VERSION}.dmg"
if [[ ! -f "${DMG_PATH}" ]]; then
  echo "Error: ${DMG_PATH} not found." >&2
  echo "  Run \`make dist\` first." >&2
  exit 1
fi

mkdir -p "${RELEASES_DIR}"

# Copy the current DMG into the mirror dir so generate_appcast picks it up.
# Idempotent — the mirror is the running history.
echo "==> Mirroring ${DMG_PATH} → ${RELEASES_DIR}/"
cp -f "${DMG_PATH}" "${RELEASES_DIR}/Seshctl-${VERSION}.dmg"

# Optional: embed release notes. generate_appcast picks up a sibling
# Seshctl-<VERSION>.html file and uses it as the <description> for that
# version's <item>. We accept Markdown at docs/release-notes/<VERSION>.md
# and render it to HTML via `markdown` (Daring Fireball's reference) or
# fall back to a `<pre>`-wrapped copy if no markdown tool is on PATH.
NOTES_MD="${RELEASE_NOTES_DIR}/${VERSION}.md"
NOTES_HTML="${RELEASES_DIR}/Seshctl-${VERSION}.html"
if [[ -f "${NOTES_MD}" ]]; then
  echo "==> Rendering ${NOTES_MD} → ${NOTES_HTML}"
  if command -v markdown >/dev/null 2>&1; then
    markdown "${NOTES_MD}" > "${NOTES_HTML}"
  else
    # Minimal fallback: wrap in <pre> so the text at least renders readable.
    {
      echo "<pre>"
      sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' "${NOTES_MD}"
      echo "</pre>"
    } > "${NOTES_HTML}"
    echo "  warning: \`markdown\` not on PATH — wrote a <pre>-wrapped fallback." >&2
    echo "           Install with: brew install discount" >&2
  fi
elif [[ -f "${NOTES_HTML}" ]]; then
  # Stale render from a previous run with a since-deleted .md — clean up.
  rm -f "${NOTES_HTML}"
fi

# generate_appcast signs every artifact in the dir with the Keychain private
# key and emits a complete appcast.xml. The output path is the dir; the file
# lands at <dir>/appcast.xml. We then move it into docs/.
echo "==> Generating appcast for $(ls "${RELEASES_DIR}"/*.dmg 2>/dev/null | wc -l | tr -d ' ') DMG(s) in ${RELEASES_DIR}/"
"${GENERATE_APPCAST}" "${RELEASES_DIR}"

# generate_appcast writes <dir>/appcast.xml. Move into docs/ for Pages.
mkdir -p "${DOCS_DIR}"
mv -f "${RELEASES_DIR}/appcast.xml" "${DOCS_DIR}/appcast.xml"

echo ""
echo "==> Wrote ${DOCS_DIR}/appcast.xml"
echo ""
echo "Next steps:"
echo "  1. git diff docs/appcast.xml   # review"
echo "  2. git add docs/appcast.xml ${NOTES_MD#${REPO_DIR}/}"
echo "  3. git commit -m \"appcast: ${VERSION}\""
echo "  4. git push   # GitHub Pages rebuilds within ~60s"
