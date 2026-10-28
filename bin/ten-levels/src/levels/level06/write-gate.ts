/** Lexical write-root check; credentials are checked by per-task Git hooks. */
import { isAbsolute, relative, resolve } from "node:path";
import type { Questions, State } from "../../core/types.ts";

export type Decide = (state: State, questions: Questions) => Promise<{ answers: Record<string, unknown> }>;

export function insideRepo(path: string, repo: string): boolean {
  const target = isAbsolute(path) ? path : resolve(repo, path);
  const rel = relative(resolve(repo), target);
  return rel !== "" && !rel.startsWith("..") && !isAbsolute(rel);
}
