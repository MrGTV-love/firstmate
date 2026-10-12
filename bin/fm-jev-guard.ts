// Installs disler's ten-levels level 6 jev-guard (bin/ten-levels, see SOURCE.md
// there) into one Firstmate ship or scout worker session.
// Usage: installJevGuard(pi, {home, config, state, task, worktree, data, project}) from the
// omp extension fm-spawn.sh generates, or through bin/fm-jev-guard-claude.ts.
// The upstream extension runs unchanged. Firstmate's boundary and compatibility
// requirements are owned by docs/configuration.md "Jev guard"; SOURCE.md records
// why root selection, handler budgets and input restrictions are necessary.
import { realpathSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import jevGuard from "./ten-levels/extensions/jev-guard.ts";
import { configure, withDecisionBudget } from "./ten-levels/extensions/report.ts";
import { insideRepo } from "./ten-levels/src/levels/level06/index.ts";

export interface JevGuardContext {
  home: string;
  config: string;
  state: string;
  task: string;
  worktree: string;
  data: string;
  project?: string;
}

const navigationActions: Readonly<Record<string, true>> = {
  references: true,
  definition: true,
  implementation: true,
  type_definition: true,
  hover: true,
  symbols: true,
};

function plainPath(path: string): boolean {
  return /^[/A-Za-z0-9_.-]/.test(path) && !/^[A-Za-z][A-Za-z0-9+.-]*:/.test(path)
    && !path.endsWith("]");
}

function object(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

// Device payloads are tool invocations, not file contents for the upstream judge.
// These are bounded trusted operations, not a filesystem or process sandbox.
function admittedDevice(input: { path?: unknown; content?: unknown }, ctx: unknown, worktree: string): boolean {
  try {
    if (input.path === "xd://lsp") {
      if (typeof input.content !== "string" || !object(ctx) || typeof ctx.cwd !== "string"
        || typeof ctx.getAsyncJobSnapshot !== "function") return false;
      const args: unknown = JSON.parse(input.content);
      if (!object(args) || typeof args.action !== "string" || navigationActions[args.action] !== true
        || typeof args.file !== "string") return false;
      const root = realpathSync(worktree);
      if (realpathSync(ctx.cwd) !== root) return false;
      if (!plainPath(args.file)) return false;
      const file = realpathSync(resolve(worktree, args.file));
      return statSync(file).isFile() && insideRepo(file, root);
    }
    const job = typeof input.path === "string" ? /^proc:\/\/([A-Za-z0-9][A-Za-z0-9._-]*)\/kill$/.exec(input.path) : null;
    if (!job || !object(ctx) || typeof ctx.getAsyncJobSnapshot !== "function") return false;
    const snapshot: unknown = ctx.getAsyncJobSnapshot();
    if (!object(snapshot)) return false;
    return Array.isArray(snapshot.running)
      && snapshot.running.some((entry: unknown) => object(entry) && entry.id === job[1]);
  } catch {
    return false;
  }
}

function real(path: string): string[] {
  try {
    return [path, realpathSync(path)];
  } catch {
    return [path];
  }
}

export function installJevGuard(pi: any, c: JevGuardContext): void {
  // Set before native LSP startup; this is process-local, never a profile setting.
  process.env.PI_DISABLE_LSPMUX = "1";
  configure(c);
  const roots = [...new Set([c.worktree, ...real(c.data), ...real(tmpdir()), ...real("/tmp")])];
  const writeRoot = (event: any, ctx: any) => {
    if (event?.toolName !== "write" && event?.toolName !== "edit") return ctx;
    const path = String(event.input?.path ?? "");
    const cwd = roots.find((root) => insideRepo(path, root)) ?? c.worktree;
    return Object.defineProperty(Object.create(ctx ?? null), "cwd", { value: cwd });
  };
  jevGuard({
    on: (name: string, handler: (event: any, ctx: any) => any) =>
      pi.on(name, (event: any, ctx: any) => withDecisionBudget(async () => {
        if (name === "tool_call" && event?.toolName === "edit"
          && (typeof event.input?.path !== "string" || typeof event.input?.new_string !== "string")) {
          return { block: true, reason: "jev-guard needs omp replace edit mode. Report this configuration problem rather than working around it." };
        }
        if (name === "tool_call" && (event?.toolName === "write" || event?.toolName === "edit")) {
          const path = String(event.input?.path ?? "");
          if (event.toolName === "write" && admittedDevice(event.input ?? {}, ctx, c.worktree)) return;
          if (!plainPath(path)) {
            return { block: true, reason: "jev-guard needs a plain absolute or worktree-relative path. Use one, and report if that is not possible rather than working around this block." };
          }
        }
        return handler(event, writeRoot(event, ctx));
      })),
    appendEntry: (...args: unknown[]) => pi.appendEntry?.(...args),
  });
}
