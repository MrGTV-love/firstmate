// Installs disler's ten-levels level 6 jev-guard (bin/ten-levels, see SOURCE.md
// there) into one Firstmate ship or scout worker session.
// Usage: installJevGuard(pi, {home, config, state, task, worktree, data}) from the
// omp extension fm-spawn.sh generates, or through bin/fm-jev-guard-claude.ts.
// The upstream extension runs unchanged. This glue only configures the owning
// home for key, never-send policy and ledger, and picks the write gate's repo
// root: a write or edit inside the task's data directory or the system temp
// directory is judged against that root instead of being blocked as outside
// the worktree; every other path is judged against the worktree.
import { realpathSync } from "node:fs";
import { tmpdir } from "node:os";
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
}

function real(path: string): string[] {
  try {
    return [path, realpathSync(path)];
  } catch {
    return [path];
  }
}

export function installJevGuard(pi: any, c: JevGuardContext): void {
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
        return handler(event, writeRoot(event, ctx));
      })),
    appendEntry: (...args: unknown[]) => pi.appendEntry?.(...args),
  });
}
