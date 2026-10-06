// Supported omp tool_call adapter. The shared screen alone owns selection,
// privacy, Jev and accounting. No handler ever returns a block or altered input.
// Also installed into generated fleet worker extensions by fm-spawn.sh.
import { spawn } from "node:child_process";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const registered = new WeakSet<object>();
type API = { on: (name: string, handler: (event: unknown) => unknown) => void };
type GuardrailContext = {
  FM_HOME: string;
  FM_CONFIG_OVERRIDE: string;
  FM_STATE_OVERRIDE: string;
};

function observe(payload: object, context?: GuardrailContext) {
  return new Promise<void>((done) => {
    const child = spawn("node", [resolve(root, "bin/fm-jev-guardrail.mjs"), "hook", "--host", "omp"], { env: { ...process.env, ...context }, stdio: ["pipe", "ignore", "ignore"] });
    child.on("error", () => done());
    child.on("close", () => done());
    child.stdin.on("error", () => {});
    child.stdin.end(JSON.stringify(payload));
  });
}

export function installGuardrail(pi: API, context?: GuardrailContext) {
  // The generated worker adapter owns task registration, including Firstmate
  // task copies whose auto-discovered module has a different physical root.
  if (registered.has(pi)) return;
  registered.add(pi);
  pi.on("tool_call", async (event) => {
    if (!event || typeof event !== "object" || !("toolName" in event) ||
        typeof event.toolName !== "string" || !["bash", "read"].includes(event.toolName) ||
        !("input" in event)) return;
    await observe({ toolName: event.toolName, input: event.input }, context);
  });
}

export default function (pi: API) {
  if (process.env.FM_TASK_ID) return;
  installGuardrail(pi);
}
