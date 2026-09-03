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
#   - hooks = true line in ~/.agents/config.toml (and [features] if empty)
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
strip_seshctl_hooks() {
    local file="$1"
    [ -f "$file" ] || return 0

    if [ "$have_jq" -eq 1 ]; then
        local tmp
        tmp="$(mktemp)"
        if jq --arg prefix "$HOOK_PREFIX" '
            if .hooks then
                .hooks |= with_entries(
                    .value |= map(select(
                        (.hooks // []) | map(.command // "") | map(startswith($prefix)) | any | not
                    ))
                    | .value |= (if length == 0 then empty else . end)
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

echo "==> Clearing Codex hooks flag from $CODEX_CONFIG"
if [ -f "$CODEX_CONFIG" ]; then
    # One section-aware pass mirroring the Swift clearCodexConfigFlag:
    #   - drop the flag line (current `hooks` and deprecated `codex_hooks`
    #     spellings) ONLY while inside [features]. `hooks` is a generic key
    #     name; a same-named key under another section belongs to some other
    #     tool and must survive untouched.
    #   - drop the [features] header too when the section ends up with no
    #     real (non-blank, non-comment) keys — install only writes
    #     [features] / hooks when we put it there, so cleaning it up is part
    #     of "leave no trace."
    # awk exits 0 only if it actually removed a flag line, so an untouched
    # config is never rewritten.
    if awk '
        BEGIN { in_features=0; kept=0; buf=""; cleared=0 }
        /^[[:space:]]*\[/ {
            # Section header. Anything buffered belongs to a [features]
            # section that never showed a real key — drop it.
            buf=""
            kept=0
            if ($0 ~ /^[[:space:]]*\[features\][[:space:]]*$/) {
                in_features=1
                buf=$0
            } else {
                in_features=0
                print
            }
            next
        }
        in_features==1 && /^[[:space:]]*(codex_)?hooks = true[[:space:]]*$/ {
            cleared=1
            next
        }
        in_features==1 && kept==0 && ($0 ~ /^[[:space:]]*$/ || $0 ~ /^[[:space:]]*#/) {
            # Blank or comment before any real key — buffer it; the whole
            # section may still turn out to be ours to delete.
            buf = buf "\n" $0
            next
        }
        in_features==1 && kept==0 {
            # First real key: [features] survives. Flush the buffered header
            # (plus any blanks/comments) and print this line too.
            print buf
            buf=""
            kept=1
            print
            next
        }
        { print }
        END {
            if (cleared == 1) { exit 0 }
            exit 1
        }
    ' "$CODEX_CONFIG" > "$CODEX_CONFIG.tmp"; then
        mv "$CODEX_CONFIG.tmp" "$CODEX_CONFIG"
        echo "  cleared hooks = true from $CODEX_CONFIG"
    else
        rm -f "$CODEX_CONFIG.tmp"
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
