#!/usr/bin/env bash
# Assemble dist/Seshctl.app from SwiftPM build output. No code signing — that's
# Step 2. Builds a universal (arm64 + x86_64) release binary, copies it plus
# the CLI into the bundle's MacOS/ directory, and installs Info.plist.
set -euo pipefail

# REPO_DIR is the parent of the directory containing this script.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${REPO_DIR}"

echo "==> Building universal release (arm64 + x86_64) ..."
# Note: this can be slow (universal builds compile twice). The Makefile/user is
# responsible for the AGENTS.md 120s timeout convention; we don't enforce it
# here because GNU `timeout` isn't on macOS by default.
swift build -c release --arch arm64 --arch x86_64

# Universal builds with --arch flags land under .build/apple/Products/Release.
# Single-arch fallback is .build/release/. We try universal first and warn on
# fallback so Step 2/4 can re-attempt universal once signing is in place.
PRODUCTS_DIR="${REPO_DIR}/.build/apple/Products/Release"
if [[ ! -x "${PRODUCTS_DIR}/SeshctlApp" || ! -x "${PRODUCTS_DIR}/seshctl-cli" ]]; then
	echo "WARN: universal binaries not found at ${PRODUCTS_DIR}; falling back to single-arch .build/release/" >&2
	PRODUCTS_DIR="${REPO_DIR}/.build/release"
fi

if [[ ! -x "${PRODUCTS_DIR}/SeshctlApp" || ! -x "${PRODUCTS_DIR}/seshctl-cli" ]]; then
	echo "ERROR: expected SeshctlApp and seshctl-cli in ${PRODUCTS_DIR}" >&2
	ls -la "${PRODUCTS_DIR}" >&2 || true
	exit 1
fi

BUNDLE_DIR="${REPO_DIR}/dist/Seshctl.app"
echo "==> Recreating bundle at ${BUNDLE_DIR} ..."
rm -rf "${BUNDLE_DIR}"
mkdir -p "${BUNDLE_DIR}/Contents/MacOS"
mkdir -p "${BUNDLE_DIR}/Contents/Resources"

echo "==> Copying binaries ..."
cp "${PRODUCTS_DIR}/SeshctlApp" "${BUNDLE_DIR}/Contents/MacOS/SeshctlApp"
cp "${PRODUCTS_DIR}/seshctl-cli" "${BUNDLE_DIR}/Contents/MacOS/seshctl-cli"
chmod +x "${BUNDLE_DIR}/Contents/MacOS/SeshctlApp"
chmod +x "${BUNDLE_DIR}/Contents/MacOS/seshctl-cli"

echo "==> Copying Info.plist ..."
# Entitlements are NOT copied into the bundle — codesign reads them via
# --entitlements at sign time. Only Info.plist ships inside the bundle.
cp "${REPO_DIR}/Resources/Info.plist" "${BUNDLE_DIR}/Contents/Info.plist"

# Embed Sparkle.framework. SwiftPM resolves Sparkle's binary xcframework and,
# for the universal release build, drops a flattened Sparkle.framework right
# alongside the SeshctlApp binary in PRODUCTS_DIR. We copy it to the standard
# Contents/Frameworks/ location and add @executable_path/../Frameworks to
# SeshctlApp's rpath (SwiftPM's default rpath is .../lib only, which won't
# find it at Contents/Frameworks).
echo "==> Embedding Sparkle.framework ..."
SPARKLE_SRC="${PRODUCTS_DIR}/Sparkle.framework"
if [[ ! -d "${SPARKLE_SRC}" ]]; then
	echo "ERROR: Sparkle.framework not found at ${SPARKLE_SRC}" >&2
	echo "       Expected the universal SwiftPM build to drop the resolved framework here." >&2
	exit 1
fi
mkdir -p "${BUNDLE_DIR}/Contents/Frameworks"
# -R preserves the Versions/Current symlinks Apple's framework layout needs.
cp -R "${SPARKLE_SRC}" "${BUNDLE_DIR}/Contents/Frameworks/Sparkle.framework"

# Add the runtime search path so dyld finds @rpath/Sparkle.framework/...
# Idempotent: skip if already present (cheap insurance against re-use).
if ! otool -l "${BUNDLE_DIR}/Contents/MacOS/SeshctlApp" \
		| grep -A 2 LC_RPATH | grep -qF "@executable_path/../Frameworks"; then
	install_name_tool -add_rpath "@executable_path/../Frameworks" \
		"${BUNDLE_DIR}/Contents/MacOS/SeshctlApp"
fi

echo "==> Building and bundling VS Code / Cursor extension ..."
# ExtensionInstaller reads these at runtime from Contents/Resources/extensions/.
# The .vsix is the prebuilt extension; the .version sidecar is the source of
# truth for "what version are we shipping" — avoids parsing the .vsix zip at
# runtime. Both must exist for the onboarding pane to work.
if ! command -v npm >/dev/null 2>&1; then
	echo "ERROR: 'npm' is required to bundle the editor extension. Install Node (via asdf is recommended)." >&2
	echo "       See docs/release.md for the full build-host dependency list." >&2
	exit 1
fi

EXT_DIR="${BUNDLE_DIR}/Contents/Resources/extensions"
mkdir -p "${EXT_DIR}"
(
	cd "${REPO_DIR}/vscode-extension"
	npm install --no-audit --no-fund
	npm run build
	npm exec -- @vscode/vsce package --allow-missing-repository --out "${EXT_DIR}/seshctl.vsix"
)
python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["version"])' \
	"${REPO_DIR}/vscode-extension/package.json" > "${EXT_DIR}/seshctl.vsix.version"

if [[ ! -s "${EXT_DIR}/seshctl.vsix" || ! -s "${EXT_DIR}/seshctl.vsix.version" ]]; then
	echo "ERROR: vsix or version sidecar is missing or empty after build" >&2
	ls -la "${EXT_DIR}" >&2 || true
	exit 1
fi

echo "==> Copying hook templates ..."
# FirstLaunchInstaller reads these from Contents/Resources/hooks/{claude,codex,cursor}
# at install time, prepends the defensive guard, and writes the result to
# ~/.local/share/seshctl/hooks/. Without these in the bundle, the welcome
# panel's Install button fails with `hookSourceNotFound`.
mkdir -p "${BUNDLE_DIR}/Contents/Resources/hooks"
cp -R "${REPO_DIR}/hooks/claude" "${BUNDLE_DIR}/Contents/Resources/hooks/claude"
cp -R "${REPO_DIR}/hooks/codex" "${BUNDLE_DIR}/Contents/Resources/hooks/codex"
cp -R "${REPO_DIR}/hooks/cursor" "${BUNDLE_DIR}/Contents/Resources/hooks/cursor"

echo ""
echo "==> Bundle assembled."
echo "    Bundle:  ${BUNDLE_DIR}"
echo ""
ls -la "${BUNDLE_DIR}/Contents/MacOS/"
echo ""
file "${BUNDLE_DIR}/Contents/MacOS/SeshctlApp"
file "${BUNDLE_DIR}/Contents/MacOS/seshctl-cli"
