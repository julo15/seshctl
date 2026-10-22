#!/bin/bash
# Codex SessionEnd hook → seshctl-cli end
# Fires when the session terminates.
set -euo pipefail

PAYLOAD=$(cat)
SESSION_ID=$(echo "$PAYLOAD" | jq -r '.session_id // empty')

# `end` takes exactly one matcher. Prefer the conversation id: it survives a
# hook running in a different subprocess, whereas $PPID only holds while the
# same CLI process is the parent.
if [ -n "$SESSION_ID" ]; then
  seshctl-cli end --conversation-id "$SESSION_ID" --tool codex > /dev/null 2>&1
else
  seshctl-cli end --pid "$PPID" --tool codex > /dev/null 2>&1
fi
