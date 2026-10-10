// Claude Code hook adapter for the ten-levels jev-guard (bin/fm-jev-guard.ts).
// Usage: bin/fm-jev-guard-hook.sh <home> <config> <state> <task> <worktree> <data> <project> < hook.json
// Registered by fm-spawn.sh in a Claude worker's .claude/settings.local.json:
// PreToolUse Bash|Write|Edit runs the upstream tool_call handler and
// PostToolUse Bash|Read runs its tool_result handler. A block becomes a
// PreToolUse deny with the upstream reason. Claude cannot replace a built-in
// tool's output, so a result-screen banner arrives as PostToolUse
// additionalContext instead of being prepended to the output.
// Anything that cannot be judged prints nothing and exits 0, as upstream allows.
import { readFileSync } from "node:fs";
import { installJevGuard } from "./fm-jev-guard.ts";

const [home, config, state, task, worktree, data, project] = process.argv.slice(2);
const handlers: Record<string, (event: any, ctx: any) => Promise<any>> = {};
installJevGuard({ on: (name: string, handler: any) => { handlers[name] = handler; } }, { home, config, state, task, worktree, data, project });

function text(response: any): string {
  if (typeof response === "string") return response;
  if (typeof response?.file?.content === "string") return response.file.content;
  if (typeof response?.stdout === "string" || typeof response?.stderr === "string") {
    return [response.stdout, response.stderr].filter((part) => typeof part === "string" && part).join("\n");
  }
  return response === undefined ? "" : JSON.stringify(response);
}

async function main() {
  const payload = JSON.parse(readFileSync(0, "utf8"));
  const tool = String(payload.tool_name ?? "").toLowerCase();
  const input = payload.tool_input ?? {};
  const ctx = { cwd: String(payload.cwd ?? worktree) };
  if (payload.hook_event_name === "PreToolUse") {
    const event = tool === "bash"
      ? { toolName: tool, input: { command: input.command } }
      : { toolName: tool, input: { path: input.file_path, content: input.content, new_string: input.new_string } };
    const result = await handlers.tool_call?.(event, ctx);
    if (result?.block) {
      process.stdout.write(JSON.stringify({ hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: result.reason } }));
    }
    return;
  }
  if (payload.hook_event_name === "PostToolUse") {
    const original = text(payload.tool_response);
    const result = await handlers.tool_result?.({ toolName: tool, content: [{ type: "text", text: original }] }, ctx);
    const replaced = result?.content?.[0]?.text;
    if (typeof replaced === "string" && replaced.endsWith(original)) {
      const banner = replaced.slice(0, replaced.length - original.length).trim();
      if (banner) process.stdout.write(JSON.stringify({ hookSpecificOutput: { hookEventName: "PostToolUse", additionalContext: banner } }));
    }
  }
}

main().catch(() => {}).finally(() => process.exit(0));
