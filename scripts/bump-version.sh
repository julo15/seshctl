#!/usr/bin/env bash
# Bump the release version in Resources/Info.plist:
#   CFBundleShortVersionString -> the given version
#   CFBundleVersion            -> current value + 1 (Sparkle compares this)
#
# Edits the two <string> values in place so the diff is exactly two lines.
# Don't use PlistBuddy or `plutil -replace` for this: both rewrite the whole
# file in their own formatting, which churns every line of the plist.
#
# Usage: scripts/bump-version.sh 0.8.2   (or: make bump-version VERSION=0.8.2)
set -euo pipefail

PLIST="Resources/Info.plist"
NEW_SHORT="${1:-}"

if [[ ! "$NEW_SHORT" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Usage: $0 <major.minor.patch>   e.g. $0 0.8.2" >&2
  exit 1
fi

read_key() { /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST"; }  # read-only

OLD_SHORT="$(read_key CFBundleShortVersionString)"
OLD_BUILD="$(read_key CFBundleVersion)"
if [[ ! "$OLD_BUILD" =~ ^[0-9]+$ ]]; then
  echo "Error: CFBundleVersion is '$OLD_BUILD', expected an integer." >&2
  exit 1
fi
NEW_BUILD=$((OLD_BUILD + 1))

if [[ "$NEW_SHORT" == "$OLD_SHORT" ]]; then
  echo "Error: version is already $OLD_SHORT." >&2
  exit 1
fi

# Replace the <string> on the line after each key, leaving everything else
# byte-for-byte untouched.
KEY_SHORT="CFBundleShortVersionString" KEY_BUILD="CFBundleVersion" \
NEW_SHORT="$NEW_SHORT" NEW_BUILD="$NEW_BUILD" \
perl -0pi -e '
  s{(<key>\Q$ENV{KEY_SHORT}\E</key>\s*<string>)[^<]*(</string>)}{$1$ENV{NEW_SHORT}$2} or die "CFBundleShortVersionString not found\n";
  s{(<key>\Q$ENV{KEY_BUILD}\E</key>\s*<string>)[^<]*(</string>)}{$1$ENV{NEW_BUILD}$2} or die "CFBundleVersion not found\n";
' "$PLIST"

plutil -lint -s "$PLIST"
[[ "$(read_key CFBundleShortVersionString)" == "$NEW_SHORT" && "$(read_key CFBundleVersion)" == "$NEW_BUILD" ]] || {
  echo "Error: $PLIST didn't read back as $NEW_SHORT ($NEW_BUILD)." >&2
  exit 1
}

echo "==> $OLD_SHORT ($OLD_BUILD) -> $NEW_SHORT ($NEW_BUILD)"
echo "Next: write docs/release-notes/$NEW_SHORT.md, then make dist."
