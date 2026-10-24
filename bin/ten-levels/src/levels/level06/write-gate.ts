/** Lexical write-root check; credentials are checked by per-task Git hooks. */
import { isAbsolute, relative, resolve } from "node:path";

export function insideRepo(path: string, repo: string): boolean {
  const target = isAbsolute(path) ? path : resolve(repo, path);
  const rel = relative(resolve(repo), target);
  return rel !== "" && !rel.startsWith("..") && !isAbsolute(rel);
}
