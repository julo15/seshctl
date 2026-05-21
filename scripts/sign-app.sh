#!/usr/bin/env bash
# Sign dist/Seshctl.app with a code-signing identity (default: Seshctl Self-Signed).
#
# Idempotent: --force on each codesign call so re-running just re-signs.
#
# Order matters: nested binaries (the CLI) are signed FIRST with their own
# entitlements, then the outer .app is signed with its entitlements. We do NOT
# use --deep — that would re-sign the CLI without its specific entitlements.
#
# --timestamp=none is used because Apple's TSA only signs Apple-issued certs.
# Phase 1B (Developer ID) will switch to plain --timestamp.

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_DIR="$( cd "${SCRIPT_DIR}/.." && pwd )"

BUNDLE_DIR="${BUNDLE_DIR:-${REPO_DIR}/dist/Seshctl.app}"
IDENTITY="Seshctl Self-Signed"

# Parse args.
while [[ $# -gt 0 ]]; do
  case "$1" in
    --identity)
      IDENTITY="${2:-}"
      if [[ -z "${IDENTITY}" ]]; then
        echo "Error: --identity requires a value" >&2
        exit 2
      fi
      shift 2
      ;;
    -h|--help)
      cat <<EOF
Usage: $(basename "$0") [--identity <name>]

  --identity <name>   Code-signing identity to use (default: "Seshctl Self-Signed").
                      For Phase 1B, pass e.g. "Developer ID Application: <Name> (<Team ID>)".

Environment:
  BUNDLE_DIR          Path to .app to sign (default: dist/Seshctl.app in repo).
EOF
      exit 0
      ;;
    *)
      echo "Error: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

APP_ENT="${REPO_DIR}/Resources/Seshctl.entitlements"
CLI_ENT="${REPO_DIR}/Resources/SeshctlCLI.entitlements"
APP_BIN="${BUNDLE_DIR}/Contents/MacOS/SeshctlApp"
CLI_BIN="${BUNDLE_DIR}/Contents/MacOS/seshctl-cli"

# 1. Identity exists? Use `find-identity -p codesigning` WITHOUT `-v` — a
#    self-signed cert chains to no trusted root and is reported as
#    CSSMERR_TP_NOT_TRUSTED by the validator, but codesign signs with it fine.
if ! security find-identity -p codesigning | grep -qF " \"${IDENTITY}\""; then
  echo "Error: code-signing identity '${IDENTITY}' not found in keychain." >&2
  echo "" >&2
  echo "  For the default self-signed identity, run:" >&2
  echo "    bash ${REPO_DIR}/scripts/generate-self-signed-cert.sh" >&2
  echo "" >&2
  echo "  Then re-run this script." >&2
  exit 1
fi

# 2. Bundle binaries exist?
if [[ ! -x "${APP_BIN}" || ! -x "${CLI_BIN}" ]]; then
  echo "Error: expected binaries not found in bundle:" >&2
  echo "    ${APP_BIN}" >&2
  echo "    ${CLI_BIN}" >&2
  echo "" >&2
  echo "  Run \`make bundle\` first." >&2
  exit 1
fi

# 3. Entitlement files exist?
for f in "${APP_ENT}" "${CLI_ENT}"; do
  if [[ ! -f "${f}" ]]; then
    echo "Error: entitlements file missing: ${f}" >&2
    exit 1
  fi
done

echo "Signing with identity: ${IDENTITY}"
echo "  Bundle: ${BUNDLE_DIR}"
echo ""

# 4. Sign embedded Sparkle.framework innards before the outer .app.
#    Sparkle ships pre-signed adhoc; the outer bundle's signature includes
#    hashes of every nested item, so we must re-sign each with our identity
#    in inside-out order. No entitlements on these helpers — they're not
#    Automation clients.
SPARKLE_FW="${BUNDLE_DIR}/Contents/Frameworks/Sparkle.framework"
if [[ -d "${SPARKLE_FW}" ]]; then
  echo "→ Signing Sparkle helpers (nested)"
  # XPC services are sandbox-only at runtime but bundled regardless; the
  # outer signature still wraps their hashes, so they need signing.
  for xpc in "${SPARKLE_FW}/Versions/B/XPCServices/Downloader.xpc" \
             "${SPARKLE_FW}/Versions/B/XPCServices/Installer.xpc"; do
    if [[ -d "${xpc}" ]]; then
      codesign --force --sign "${IDENTITY}" --options runtime --timestamp=none "${xpc}"
    fi
  done
  # Updater.app and Autoupdate are the helpers Sparkle launches during install.
  codesign --force --sign "${IDENTITY}" --options runtime --timestamp=none \
    "${SPARKLE_FW}/Versions/B/Updater.app"
  codesign --force --sign "${IDENTITY}" --options runtime --timestamp=none \
    "${SPARKLE_FW}/Versions/B/Autoupdate"
  # Now the framework as a whole.
  codesign --force --sign "${IDENTITY}" --options runtime --timestamp=none \
    "${SPARKLE_FW}"
fi

# 5. Sign nested CLI (innermost binary in MacOS/, minimal entitlements).
echo "→ Signing seshctl-cli (nested)"
codesign --force \
  --sign "${IDENTITY}" \
  --options runtime \
  --timestamp=none \
  --entitlements "${CLI_ENT}" \
  "${CLI_BIN}"

# 6. Sign outer .app with Automation entitlement.
#    NOT --deep on purpose; we already signed the CLI + Sparkle bits with
#    their own (or no) entitlements.
echo "→ Signing Seshctl.app (outer)"
codesign --force \
  --sign "${IDENTITY}" \
  --options runtime \
  --timestamp=none \
  --entitlements "${APP_ENT}" \
  "${BUNDLE_DIR}"

echo ""
echo "→ Verifying signature"
codesign --verify --deep --strict --verbose=2 "${BUNDLE_DIR}"

echo ""
echo "→ Identity readout"
codesign -dv --verbose=4 "${BUNDLE_DIR}" 2>&1
