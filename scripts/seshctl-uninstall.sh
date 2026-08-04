#!/bin/bash
# seshctl standalone uninstaller.
#
# This is a real file in ~/.local/bin/ (not a symlink into the bundle), so it
# survives even if the user drags Seshctl.app to the Trash. It performs the
# same cleanup as `FirstLaunchInstaller.uninstall()` but uses only `jq` + shell
# so it has no dependency on the bundle being present.
#
# What gets removed:
#   - seshctl-tagged hook entries from ~/.claude/settings.json
#   - seshctl-tagged hook entries from ~/.agents/hooks.json
#   - seshctl-tagged hook entries from ~/.cursor/hooks.json
#   - julo15.seshctl extension from VS Code / VS Code Insiders / Cursor (best effort)
#   - ~/.local/bin/seshctl, ~/.local/bin/seshctl-cli (only if symlinks)
#   - ~/.local/bin/seshctl-uninstall (this file itself)
#   - ~/.local/share/seshctl/hooks/  (NOT seshctl.db — that's user data)
#   - ~/Library/Application Support/Seshctl/
#   - codex_hooks = true line in ~/.agents/config.toml (and [features] if empty)
#
# What this does NOT touch:
#   - ~/.local/share/seshctl/seshctl.db (user data, kept like `make uninstall`)
#   - /Applications/Seshctl.app (we'll log a reminder if it's still there)
#
# Idempotent: safe to run multiple times.

set -euo pipefail

CLAUDE_SETTINGS="$HOME/.claude/settings.json"
CODEX_HOOKS="$HOME/.agents/hooks.json"
CURSOR_HOOKS="$HOME/.cursor/hooks.json"
HOOKS_DIR="$HOME/.local/share/seshctl/hooks"
HOOK_PREFIX="$HOME/.local/share/seshctl/hooks/"
CURSOR_HOOK_PREFIX="$HOME/.local/share/seshctl/hooks/cursor/"
BIN_DIR="$HOME/.local/bin"
SUPPORT_DIR="$HOME/Library/Application Support/Seshctl"
APP_BUNDLE="/Applications/Seshctl.app"
CODEX_CONFIG="$HOME/.agents/config.toml"

have_jq=1
if ! command -v jq >/dev/null 2>&1; then
    have_jq=0
    echo "warning: jq not found — falling back to a less robust JSON cleanup." >&2
fi

# Strip seshctl-tagged hook entries from a Claude/Codex settings file.
# A "seshctl-tagged" entry is one whose hooks[].command starts with the
# deployed hooks dir prefix (~/.local/share/seshctl/hooks/) — same anchored
# matcher used by the Swift installer. Anchoring keeps us from stripping
# user-defined hooks that mention "seshctl" elsewhere in their command.
#
# An event whose array empties out is dropped with `select`, NOT `|= empty`.
# jq's `|= empty` sets the key to null rather than deleting it, and Claude Code
# then refuses the file with `hooks.SessionStart must be an array of matchers;
# received null` on every launch. The `. // []` coercion additionally cleans up
# nulls left behind by earlier versions of this script.
strip_seshctl_hooks() {
    local file="$1"
    [ -f "$file" ] || return 0

    if [ "$have_jq" -eq 1 ]; then
        local tmp
        tmp="$(mktemp)"
        if jq --arg prefix "$HOOK_PREFIX" '
            if .hooks then
                .hooks |= with_entries(
                    .value |= ((. // []) | map(select(
                        (.hooks // []) | map(.command // "") | map(startswith($prefix)) | any | not
                    )))
                    | select((.value | length) > 0)
                )
                | (if (.hooks | length) == 0 then del(.hooks) else . end)
            else . end
        ' "$file" > "$tmp" 2>/dev/null; then
            mv "$tmp" "$file"
            echo "  cleaned $file"
        else
            rm -f "$tmp"
            echo "  warning: could not parse $file — left untouched" >&2
        fi
    else
        # Minimal fallback: just leave a backup and warn. We don't try to
        # hand-edit JSON without jq — too risky.
        cp "$file" "$file.seshctl-uninstall.bak"
        echo "  warning: leaving $file untouched (no jq); backup at $file.seshctl-uninstall.bak" >&2
    fi
}

# Strip seshctl-tagged hook entries from a Cursor hooks.json file.
# Cursor's schema is FLAT: `{ "version": 1, "hooks": { "<event>": [{ "command": "..." }] } }`
# — no nested `hooks: [...]` array, no `matcher` key. We anchor on the cursor
# hooks dir prefix (~/.local/share/seshctl/hooks/cursor/) to drop only the
# entries we installed. Events that become empty are left as `[]` to mirror
# what the Swift `removeCursorHookEntries` would leave if we never touched the
# event key at all — user-defined entries under any event are preserved, and
# the top-level `version` is left intact (Cursor needs it to parse the file).
strip_seshctl_cursor_hooks() {
    local file="$1"
    if [ ! -f "$file" ]; then
        echo "  $file: not present, skipping"
        return 0
    fi

    if [ "$have_jq" -eq 1 ]; then
        local tmp
        tmp="$(mktemp)"
        if jq --arg prefix "$CURSOR_HOOK_PREFIX" '
            if .hooks then
                .hooks |= (
                    to_entries
                    | map(.value |= map(select(
                        ((.command // "") | startswith($prefix)) | not
                      )))
                    | from_entries
                )
            else . end
        ' "$file" > "$tmp" 2>/dev/null; then
            mv "$tmp" "$file"
            echo "  cleaned $file"
        else
            rm -f "$tmp"
            echo "  warning: could not parse $file — left untouched" >&2
        fi
    else
        cp "$file" "$file.seshctl-uninstall.bak"
        echo "  warning: leaving $file untouched (no jq); backup at $file.seshctl-uninstall.bak" >&2
    fi
}

echo "==> Removing seshctl hook entries from settings files"
strip_seshctl_hooks "$CLAUDE_SETTINGS"
strip_seshctl_hooks "$CODEX_HOOKS"
strip_seshctl_cursor_hooks "$CURSOR_HOOKS"

# Best-effort: tell each supported editor to uninstall julo15.seshctl. Mirrors
# ExtensionInstaller.uninstallAllEditorExtensions in Swift, but here we don't
# have NSWorkspace — we hard-code the canonical /Applications paths and fall
# back to PATH for users who relocated the editor or only have its CLI shim.
# Every failure is logged and swallowed: a broken editor must never block the
# rest of the teardown.
uninstall_editor_extension() {
    local label="$1"
    local app_path="$2"
    local cli_name="$3"
    local cli="${app_path}/Contents/Resources/app/bin/${cli_name}"
    if [ ! -x "$cli" ]; then
        cli="$(command -v "$cli_name" 2>/dev/null || true)"
    fi
    if [ -z "$cli" ] || [ ! -x "$cli" ]; then
        return 0
    fi
    if ! "$cli" --list-extensions 2>/dev/null | grep -qx 'julo15.seshctl'; then
        return 0
    fi
    if "$cli" --uninstall-extension julo15.seshctl >/dev/null 2>&1; then
        echo "  removed extension from ${label}"
    else
        echo "  warning: failed to uninstall extension from ${label}" >&2
    fi
}

echo "==> Uninstalling Seshctl extension from editors"
uninstall_editor_extension "VS Code" "/Applications/Visual Studio Code.app" "code"
uninstall_editor_extension "VS Code Insiders" "/Applications/Visual Studio Code - Insiders.app" "code-insiders"
uninstall_editor_extension "Cursor" "/Applications/Cursor.app" "cursor"

echo "==> Removing CLI symlinks from $BIN_DIR"
for link in "$BIN_DIR/seshctl" "$BIN_DIR/seshctl-cli"; do
    if [ -L "$link" ]; then
        rm -f "$link"
        echo "  removed symlink $link"
    elif [ -e "$link" ]; then
        echo "  skipping $link (real file, not a symlink — leaving it alone)"
    fi
done

echo "==> Removing hook scripts directory"
if [ -d "$HOOKS_DIR" ]; then
    rm -rf "$HOOKS_DIR"
    echo "  removed $HOOKS_DIR"
fi

echo "==> Clearing codex_hooks flag from $CODEX_CONFIG"
if [ -f "$CODEX_CONFIG" ]; then
    if grep -q '^codex_hooks = true$' "$CODEX_CONFIG"; then
        # Drop the flag line.
        sed -i '' '/^codex_hooks = true$/d' "$CODEX_CONFIG"
        # If [features] is now empty (no key/value lines between it and the next
        # header or EOF), drop the header line too. This mirrors the Swift
        # clearCodexConfigFlag — install only writes [features] / codex_hooks
        # when we put it there, so cleaning it up is part of "leave no trace."
        awk '
            BEGIN { features=0; buf="" }
            /^\[features\][[:space:]]*$/ {
                features=1; buf=$0; next
            }
            features==1 {
                if ($0 ~ /^\[/) {
                    # Hit the next section header. [features] is empty —
                    # drop the saved header line and continue.
                    features=0
                    print
                    next
                }
                if ($0 ~ /^[[:space:]]*$/) {
                    # Blank line inside [features] — buffer it; we still
                    # might find a non-blank key below.
                    buf = buf "\n" $0
                    next
                }
                # Any non-blank, non-header line = [features] is non-empty.
                # Flush the buffered header (and any blanks) and print this
                # line as well.
                print buf
                print $0
                features=0
                next
            }
            features==0 { print }
            END {
                # If we hit EOF while still inside an empty [features], drop
                # the buffered header. Otherwise we already flushed it.
            }
        ' "$CODEX_CONFIG" > "$CODEX_CONFIG.tmp" && mv "$CODEX_CONFIG.tmp" "$CODEX_CONFIG"
        echo "  cleared codex_hooks = true from $CODEX_CONFIG"
    fi
fi

echo "==> Removing application support directory"
if [ -d "$SUPPORT_DIR" ]; then
    rm -rf "$SUPPORT_DIR"
    echo "  removed $SUPPORT_DIR"
fi

for candidate in "/Applications/Seshctl.app" "$HOME/Applications/Seshctl.app" "$HOME/Downloads/Seshctl.app"; do
    if [ -d "$candidate" ]; then
        echo "Seshctl.app is still installed at $candidate — drag it to Trash to complete uninstall."
        break
    fi
done

# Self-delete last so the rest of the script always runs first.
SELF="$BIN_DIR/seshctl-uninstall"
if [ -f "$SELF" ]; then
    rm -f "$SELF"
fi

echo ""
echo "seshctl uninstalled."
