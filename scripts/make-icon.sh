#!/usr/bin/env bash
#
# Render Resources/AppIcon.svg into Resources/AppIcon.icns.
#
# The SVG is the source of truth; the .icns is a generated artifact that is
# committed so `make bundle` works on a machine without rsvg-convert. Re-run
# this only when the SVG changes.
#
# Requires: rsvg-convert (brew install librsvg), iconutil (ships with macOS).
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SVG="${REPO_DIR}/Resources/AppIcon.svg"
ICNS="${REPO_DIR}/Resources/AppIcon.icns"
ICONSET="$(mktemp -d)/AppIcon.iconset"

if ! command -v rsvg-convert >/dev/null 2>&1; then
  echo "error: rsvg-convert not found. Install with: brew install librsvg" >&2
  exit 1
fi

if [ ! -f "${SVG}" ]; then
  echo "error: ${SVG} not found" >&2
  exit 1
fi

mkdir -p "${ICONSET}"

# Apple's required iconset members. Each @2x is the same pixel size as the next
# tier up but must exist under its own name, so render both rather than
# symlinking — iconutil rejects symlinks.
render() {
  rsvg-convert -w "$1" -h "$1" "${SVG}" -o "${ICONSET}/$2"
}

render 16   icon_16x16.png
render 32   icon_16x16@2x.png
render 32   icon_32x32.png
render 64   icon_32x32@2x.png
render 128  icon_128x128.png
render 256  icon_128x128@2x.png
render 256  icon_256x256.png
render 512  icon_256x256@2x.png
render 512  icon_512x512.png
render 1024 icon_512x512@2x.png

iconutil --convert icns "${ICONSET}" --output "${ICNS}"

echo "wrote ${ICNS} ($(du -h "${ICNS}" | cut -f1))"
