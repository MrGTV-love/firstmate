// Claude hook adapter for bin/fm-jev-guard.ts; fm-jev-guard-hook.sh owns invocation.
// PreToolUse denies required unavailable judgments. PostToolUse is deliberately
// advisory-only/no protection without installed-host output-replacement proof.
import { createHash } from "node:crypto";
import { appendFileSync, mkdirSync, readFileSync } from "node:fs";
import { resolve } from "node:path";
import { hostReadBindings, installJevGuard, type GuardCallHandler, type GuardPromptHandler, type GuardResultHandler } from "./fm-jev-guard.ts";

const [home, config, state, task, worktree, data, project, policy] = process.argv.slice(2);

function object(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function text(response: unknown): string {
  if (typeof response === "string") return response;
  if (object(response)) {
    if (object(response.file) && typeof response.file.content === "string") return response.file.content;
    if (typeof response.stdout === "string" || typeof response.stderr === "string") {
      return [response.stdout, response.stderr].filter((part): part is string => typeof part === "string" && part.length > 0).join("\n");
    }
  }
  return response === undefined ? "" : JSON.stringify(response);
}

async function main(): Promise<void> {
  if (policy !== "FIRSTMATE_JEV_GUARD_V1") return;
  const payload: unknown = JSON.parse(readFileSync(0, "utf8"));
  if (!object(payload)) throw new Error("Invalid hook input.");
  const session = typeof payload.session_id === "string" && payload.session_id.length > 0
    ? createHash("sha256").update(payload.session_id, "utf8").digest("hex") : undefined;
  // Claude starts a separate process per hook. This task/session-local context
  // stores only native UserPromptSubmit path/doorbell binding hashes, never prompt contents.
  // It has the same-user forgery limit of the publisher consistency receipt;
  // it is not producer authentication and introduces no service or key.
  const cache = session ? resolve(data, `jev-guard-doorbells-${session}.jsonl`) : undefined;
  if (payload.hook_event_name === "UserPromptSubmit") {
    if (project !== "firstmate") return;
    const hashes = hostReadBindings(payload.prompt, { state, task });
    if (hashes.length === 0) return;
    if (!cache) throw new Error("Missing native session.");
    mkdirSync(data, { recursive: true });
    appendFileSync(cache, JSON.stringify({ read_binding_sha256: hashes, error_type: null }) + "\n", { mode: 0o600 });
    return;
  }
  if (typeof payload.tool_name !== "string") throw new Error("Invalid hook input.");
  const tool = payload.tool_name.toLowerCase();
  const doorbells = new Set<string>();
  if (project === "firstmate" && tool === "read" && payload.hook_event_name === "PostToolUse" && cache) {
    let saved = "";
    try {
      saved = readFileSync(cache, "utf8");
    } catch (error) {
      if (!object(error) || error.code !== "ENOENT") throw error;
    }
    for (const line of saved.split("\n")) {
      if (line === "") continue;
      const row: unknown = JSON.parse(line);
      if (!object(row) || row.error_type !== null || !Array.isArray(row.read_binding_sha256)) throw new Error("Invalid native context.");
      for (const hash of row.read_binding_sha256) {
        if (typeof hash !== "string" || !/^[0-9a-f]{64}$/.test(hash)) throw new Error("Invalid native context.");
        doorbells.add(hash);
      }
    }
  }
  type Handlers = { tool_call: GuardCallHandler; tool_result: GuardResultHandler; before_agent_start: GuardPromptHandler };
  const handlers: Partial<Handlers> = {};
  installJevGuard({ on<K extends keyof Handlers>(name: K, handler: Handlers[K]) { handlers[name] = handler; } },
    { home, config, state, task, worktree, data, project, policy, host: "claude", hostReadBindings: doorbells });
  const input = object(payload.tool_input) ? payload.tool_input : {};
  const ctx = { cwd: typeof payload.cwd === "string" ? payload.cwd : worktree };
  const toolCallId = typeof payload.tool_use_id === "string" ? payload.tool_use_id : undefined;
  const mapped = tool === "bash" ? { command: input.command }
    : { path: input.file_path, content: input.content, new_string: input.new_string };

  if (payload.hook_event_name === "PreToolUse") {
    const handler = handlers.tool_call;
    if (!handler) throw new Error("Missing pre-tool handler.");
    const result = await handler({ toolName: tool, toolCallId, input: mapped }, ctx);
    if (result?.block) {
      process.stdout.write(JSON.stringify({ hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: result.reason } }));
    }
  } else if (payload.hook_event_name === "PostToolUse") {
    const handler = handlers.tool_result;
    if (!handler) throw new Error("Missing post-tool handler.");
    const result = await handler({ toolName: tool, toolCallId, input: mapped,
      content: [{ type: "text", text: text(payload.tool_response) }] }, ctx);
    if (result) {
      const additionalContext = "additionalContext" in result ? result.additionalContext : result.content[0].text;
      process.stdout.write(JSON.stringify({ hookSpecificOutput: { hookEventName: "PostToolUse", additionalContext } }));
    }
  }
}

main().catch(() => {
  if (project !== "firstmate") return;
  // Exit 2 stops pre-tool execution; on post-tool hooks it is feedback, not quarantine.
  process.stderr.write("[jev-guard] Review required: HookInputError. REVIEW_ON_UNAVAILABLE_V1.\n");
  process.exitCode = 2;
});
