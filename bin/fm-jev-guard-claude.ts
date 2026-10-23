// Claude hook adapter for bin/fm-jev-guard.ts; fm-jev-guard-hook.sh owns invocation.
// The post-tool advisory was retired on 2026-10-22: it could only append context on
// Claude, never withhold output, so it reported protection it did not provide.
// The pre-tool deny below is this integration's only coverage.
// Do not re-add a post-tool branch here without installed-host output-replacement proof.
import { readFileSync } from "node:fs";
import { installJevGuard, type GuardCallHandler, type GuardPromptHandler, type GuardResultHandler } from "./fm-jev-guard.ts";

const [home, config, state, task, worktree, data, project, policy] = process.argv.slice(2);

function object(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

async function main(): Promise<void> {
  if (policy !== "FIRSTMATE_JEV_GUARD_V1") return;
  const payload: unknown = JSON.parse(readFileSync(0, "utf8"));
  if (!object(payload)) throw new Error("Invalid hook input.");
  // The retired event returns before any handler is installed, so the hook prints
  // nothing and exits 0 instead of appending advisory context to the result.
  if (payload.hook_event_name !== "PreToolUse") return;
  if (typeof payload.tool_name !== "string") throw new Error("Invalid hook input.");
  const tool = payload.tool_name.toLowerCase();
  // GuardHost still requires all three registrations; this adapter drives only tool_call.
  type Handlers = { tool_call: GuardCallHandler; tool_result: GuardResultHandler; before_agent_start: GuardPromptHandler };
  const handlers: Partial<Handlers> = {};
  installJevGuard({ on<K extends keyof Handlers>(name: K, handler: Handlers[K]) { handlers[name] = handler; } },
    { home, config, state, task, worktree, data, project, policy, host: "claude" });
  const input = object(payload.tool_input) ? payload.tool_input : {};
  const ctx = { cwd: typeof payload.cwd === "string" ? payload.cwd : worktree };
  const toolCallId = typeof payload.tool_use_id === "string" ? payload.tool_use_id : undefined;
  const mapped = tool === "bash" ? { command: input.command }
    : { path: input.file_path, content: input.content, new_string: input.new_string };
  const handler = handlers.tool_call;
  if (!handler) throw new Error("Missing pre-tool handler.");
  const result = await handler({ toolName: tool, toolCallId, input: mapped }, ctx);
  if (result?.block) {
    process.stdout.write(JSON.stringify({ hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: result.reason } }));
  }
}

main().catch(() => {
  if (project !== "firstmate") return;
  // Exit 2 stops pre-tool execution; it is the pre-tool fail-safe, not advisory feedback.
  process.stderr.write("[jev-guard] Review required: HookInputError. REVIEW_ON_UNAVAILABLE_V1.\n");
  process.exitCode = 2;
});
