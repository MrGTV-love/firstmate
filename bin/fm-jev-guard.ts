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

function editTargets(input: any): { path: string; content: string }[] {
  const unquote = (value: string) => {
    const path = value.trim();
    return /^(['"]).*\1$/.test(path) ? path.slice(1, -1) : path;
  };
  const raw = input?.input ?? input?._input;
  if (typeof raw === "string") {
    const targets: { path: string; content: string }[] = [];
    let paths: string[] = [];
    let body: string[] = [];
    const flush = () => {
      const content = body.join("\n");
      for (const path of paths) targets.push({ path, content });
      paths = [];
      body = [];
    };
    for (const line of raw.replace(/^\uFEFF/, "").split(/\r?\n/)) {
      const header = /^\[(.*?)(?:#[0-9a-fA-F]{4})?\]$/.exec(line)
        ?? /^\s*¶+(.*?)(?:#[0-9a-fA-F]{4})?\s*$/.exec(line)
        ?? /^\*\*\* (?:Add|Update|Delete) File: (.+)$/.exec(line);
      if (header) {
        flush();
        paths.push(unquote(header[1]));
      } else {
        const move = /^(?:MV |\*\*\* Move to: )(.+)$/.exec(line);
        if (move) paths.push(unquote(move[1]));
        else if (line.startsWith("+")) body.push(line.slice(1));
      }
    }
    flush();
    return targets;
  }
  const path = String(input?.path ?? input?._path ?? "");
  if (Array.isArray(input?.edits)) {
    const paths = [...new Set<string>([path, ...input.edits.filter((edit: any) => typeof edit.rename === "string").map((edit: any) => edit.rename)])];
    return input.edits.flatMap((edit: any) => {
      const content = String(edit.diff ?? edit.new_string ?? "");
      return paths.map((path) => ({ path, content }));
    });
  }
  return [{ path, content: String(input?.content ?? input?.newText ?? input?.new_string ?? "") }];
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
        if (name !== "tool_call" || event?.toolName !== "edit") {
          return handler(event, writeRoot(event, ctx));
        }
        for (const input of editTargets(event.input)) {
          const view = { ...event, input };
          const result = await handler(view, writeRoot(view, ctx));
          if (result?.block) return result;
        }
      })),
    appendEntry: (...args: unknown[]) => pi.appendEntry?.(...args),
  });
}
