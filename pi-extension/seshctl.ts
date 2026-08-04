// seshctl companion extension for Pi.
//
// Pi has no hook system — no hook flags, no hooks.json, no SessionStart /
// UserPromptSubmit / PreToolUse events anywhere in the package. What it has
// instead is a TypeScript extension API, so this file is Pi's equivalent of
// the `hooks/<tool>/*.sh` bundles the other tools use. It reports session
// lifecycle to `seshctl-cli` so Pi sessions appear in the panel with the same
// working/idle states as Claude Code and Codex.
//
// Installed to `<PI_CODING_AGENT_DIR|~/.pi/agent>/extensions/seshctl.ts` by
// FirstLaunchInstaller. Keep the event mapping in sync with the shell hooks:
//
//   session_start        -> seshctl-cli start
//   before_agent_start   -> seshctl-cli update --status working --ask <prompt>
//   agent_settled        -> seshctl-cli update --status idle --reply <text>
//   session_shutdown     -> seshctl-cli end
import { spawn } from "node:child_process";
import { basename } from "node:path";

const TOOL = "pi";

/// Fire-and-forget. A session tracker must never block, slow, or crash the
/// agent it observes, so every failure path — `seshctl-cli` absent from PATH,
/// non-zero exit, spawn refused — is swallowed deliberately.
function report(args: string[]): void {
  try {
    const child = spawn("seshctl-cli", args, { stdio: "ignore", detached: true });
    child.on("error", () => {});
    child.unref();
  } catch {
    // seshctl not installed. Pi carries on exactly as if this file were absent.
  }
}

/// Pi names session files `<timestamp>_<uuid>.jsonl`. The stem is stable for
/// the life of the session and unique across them, which is what seshctl wants
/// as a conversation id. Returns undefined for an ephemeral (unsaved) session.
function conversationId(sessionFile: string | null | undefined): string | undefined {
  if (!sessionFile) return undefined;
  return basename(sessionFile).replace(/\.jsonl$/, "") || undefined;
}

/// Walks back to the newest assistant message and flattens its text. Written
/// defensively rather than against a named type: the block shape varies by
/// provider, and a tracker guessing wrong should degrade to "no preview"
/// rather than throw inside Pi's event loop.
function lastAssistantText(messages: unknown): string | undefined {
  if (!Array.isArray(messages)) return undefined;
  for (let i = messages.length - 1; i >= 0; i--) {
    const message = messages[i] as { role?: string; content?: unknown } | null;
    if (!message || message.role !== "assistant") continue;

    const content = message.content;
    if (typeof content === "string") {
      return content.trim() || undefined;
    }
    if (Array.isArray(content)) {
      const text = content
        .map((block) => {
          if (!block || typeof block !== "object") return "";
          const maybe = block as { text?: unknown };
          return typeof maybe.text === "string" ? maybe.text : "";
        })
        .join("")
        .trim();
      if (text) return text;
    }
  }
  return undefined;
}

export default function seshctl(pi: any): void {
  // `agent_settled` carries no payload, so the reply text is captured from
  // `agent_end` and flushed when the run actually settles.
  let pendingReply: string | undefined;

  pi.on("session_start", async (_event: unknown, ctx: any) => {
    const sessionFile: string | undefined = ctx?.sessionManager?.getSessionFile?.() ?? undefined;
    const args = ["start", "--tool", TOOL, "--dir", String(ctx?.cwd ?? process.cwd()), "--pid", String(process.pid)];

    const id = conversationId(sessionFile);
    if (id) args.push("--conversation-id", id);
    if (sessionFile) args.push("--transcript-path", sessionFile);

    report(args);
  });

  pi.on("before_agent_start", async (event: { prompt?: unknown }, _ctx: unknown) => {
    const args = ["update", "--pid", String(process.pid), "--tool", TOOL, "--status", "working"];
    if (typeof event?.prompt === "string" && event.prompt.trim()) {
      args.push("--ask", event.prompt);
    }
    report(args);
  });

  pi.on("agent_end", async (event: { messages?: unknown }, _ctx: unknown) => {
    pendingReply = lastAssistantText(event?.messages);
  });

  // `agent_end` fires per agent run, but Pi may still auto-retry, auto-compact
  // and retry, or drain queued follow-ups afterwards. `agent_settled` is the
  // event Pi's own docs point status integrations at: it means Pi will not
  // continue running on its own. Reporting idle on `agent_end` would flicker
  // the row back to idle mid-work.
  pi.on("agent_settled", async (_event: unknown, _ctx: unknown) => {
    const args = ["update", "--pid", String(process.pid), "--tool", TOOL, "--status", "idle"];
    if (pendingReply) args.push("--reply", pendingReply);
    pendingReply = undefined;
    report(args);
  });

  pi.on("session_shutdown", async (_event: unknown, _ctx: unknown) => {
    report(["end", "--pid", String(process.pid), "--tool", TOOL]);
  });
}
