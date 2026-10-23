// Firstmate-written deletion lists are consistency records, not authentication.
// The CLI is called under the task metadata lock by fm-jev-deletions.sh or spawn.
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { appendFileSync, lstatSync, readFileSync, realpathSync, renameSync, writeFileSync } from "node:fs";
import { isAbsolute, relative, resolve, sep } from "node:path";
import { pathToFileURL } from "node:url";

interface Context { state: string; task: string; worktree: string }
interface DeletionList { schema: "fm-authorized-deletions.v1"; task: string; worktree: string; paths: string[] }
interface Admission { paths: string[]; list_sha256: string }
const digestKey = "jev_deletions_sha256";
const hash = (bytes: string | Buffer): string => createHash("sha256").update(bytes).digest("hex");
const listPath = (c: Context): string => resolve(c.state, `${c.task}.authorized-deletions.json`);

function metaValue(meta: string, key: string): string {
  const values = meta.split("\n").filter((line) => line.startsWith(`${key}=`));
  if (values.length !== 1) throw new Error(`Missing or duplicate metadata field: ${key}`);
  return values[0].slice(key.length + 1);
}

function taskValid(task: string): void {
  if (!/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(task)) throw new Error("Invalid task ID");
}

function git(root: string, args: string[]): string {
  return execFileSync("git", ["--literal-pathspecs", "-C", root, ...args], {
    encoding: "utf8", stdio: ["ignore", "pipe", "ignore"], timeout: 10_000, maxBuffer: 4 * 1024 * 1024,
    env: { ...process.env, GIT_DIR: undefined, GIT_WORK_TREE: undefined, GIT_COMMON_DIR: undefined, GIT_INDEX_FILE: undefined },
  });
}

function rootPath(worktree: string): string {
  const root = realpathSync(worktree);
  const top = git(root, ["rev-parse", "--show-toplevel"]).replace(/\r?\n$/, "");
  if (realpathSync(top) !== root) throw new Error("Not a worktree root");
  return root;
}

function relativePath(path: string): boolean {
  return path.length > 0 && !isAbsolute(path) && !path.includes("\0") && !path.includes("\n") && !path.includes("\r")
    && path.split("/").every((part) => part !== "" && part !== "." && part !== "..");
}

function trackedFiles(root: string, paths: string[]): boolean {
  if (paths.length === 0) return false;
  const entries = git(root, ["ls-tree", "-rz", "--full-tree", "HEAD", "--", ...paths]).split("\0").filter(Boolean);
  const tracked = new Set(entries.flatMap((entry) => {
    const match = /^100(?:644|755) blob [0-9a-f]+\t([\s\S]+)$/.exec(entry);
    return match ? [match[1]] : [];
  }));
  return paths.every((path) => relativePath(path) && tracked.has(path)
    && realpathSync(resolve(root, path)) === resolve(root, path) && lstatSync(resolve(root, path)).isFile());
}

// Deliberately not a shell interpreter. Only one literal rm with literal file
// operands is provable here. Expansions, globs, directories and compound shell
// commands retain ordinary Jev screening, even when some operands are listed.
function operands(command: string): string[] | undefined {
  if (command.length > 16_384 || /[\\$`;&|<>(){}\[\]*?!~#\n\r\0]/.test(command)) return;
  const words: string[] = [];
  let word = "", quote = "", started = false;
  for (const char of command) {
    if (quote) {
      if (char === quote) quote = "";
      else word += char;
      started = true;
    } else if (char === "'" || char === '"') {
      quote = char;
      started = true;
    } else if (char === " " || char === "\t") {
      if (started) words.push(word);
      word = "";
      started = false;
    } else {
      word += char;
      started = true;
    }
  }
  if (quote) return;
  if (started) words.push(word);
  const executable = words.shift();
  if (executable !== "rm" && executable !== "/bin/rm") return;
  let options = true;
  const paths: string[] = [];
  for (const word of words) {
    if (options && word === "--") { options = false; continue; }
    if (options && word.startsWith("-")) {
      if (!/^-[frv]+$/.test(word) && !["--force", "--recursive", "--verbose"].includes(word)) return;
    } else {
      options = false;
      if (!word || word.startsWith("-")) return;
      paths.push(word);
    }
  }
  return paths.length > 0 ? paths : undefined;
}

/** No exception on an absent, changed or unreadable consistency record. */
export function authorizedDeletion(command: string, cwd: string, c: Context): Admission | undefined {
  try {
    taskValid(c.task);
    const targets = operands(command);
    if (!targets || targets.some((target) => target.split("/").includes(".."))) return;
    const root = rootPath(c.worktree);
    const working = realpathSync(cwd);
    const workingRelative = relative(root, working);
    if (isAbsolute(workingRelative) || workingRelative === ".." || workingRelative.startsWith(`..${sep}`)) return;
    const meta = readFileSync(resolve(c.state, `${c.task}.meta`), "utf8");
    if (realpathSync(metaValue(meta, "worktree")) !== root) return;
    const bytes = readFileSync(listPath(c));
    const digest = hash(bytes);
    if (metaValue(meta, digestKey) !== digest) return;
    const list: DeletionList = JSON.parse(bytes.toString("utf8"));
    if (list.schema !== "fm-authorized-deletions.v1" || list.task !== c.task || list.worktree !== root
      || !Array.isArray(list.paths) || !list.paths.every((path) => typeof path === "string" && relativePath(path))) return;
    const paths = [...new Set(targets.map((target) => relative(root, resolve(working, target)).split(sep).join("/")))];
    if (!paths.every((path) => relativePath(path) && list.paths.includes(path)) || !trackedFiles(root, paths)) return;
    return { paths, list_sha256: digest };
  } catch {
    return;
  }
}

/** Mandatory, task-local pre-execution audit. A failed append denies admission. */
export function recordDeletion(c: Context, admission: Admission): void {
  appendFileSync(resolve(c.state, `${c.task}.authorized-deletions.jsonl`), JSON.stringify({
    task: c.task, paths: admission.paths, list_sha256: admission.list_sha256, time: new Date().toISOString(),
  }) + "\n", { mode: 0o600 });
}

function briefPaths(brief: string): string[] {
  const sections = [...brief.matchAll(/^## Authorized deletions\r?\n([\s\S]*?)(?=^#{1,2} |$(?![\s\S]))/gm)];
  if (sections.length === 0) return [];
  if (sections.length !== 1) throw new Error("Duplicate Authorized deletions section");
  const block = /^\s*```json\r?\n([\s\S]*?)\r?\n```\s*$/.exec(sections[0][1]);
  if (!block) throw new Error("Authorized deletions must contain only a JSON array code block");
  const paths: unknown = JSON.parse(block[1]);
  if (!Array.isArray(paths) || !paths.every((path) => typeof path === "string" && relativePath(path))) {
    throw new Error("Authorized deletions must be worktree-relative literal paths");
  }
  return [...new Set(paths)];
}

function atomicWrite(path: string, bytes: string): void {
  const temp = `${path}.${process.pid}.tmp`;
  writeFileSync(temp, bytes, { mode: 0o600, flag: "wx" });
  renameSync(temp, path);
}

function prepare(c: Context, brief: string): string {
  taskValid(c.task);
  const root = rootPath(c.worktree);
  const paths = briefPaths(readFileSync(brief, "utf8"));
  if (paths.length && !trackedFiles(root, paths)) throw new Error("Every listed path must be a regular HEAD-tracked file without symlink aliases");
  const bytes = JSON.stringify({ schema: "fm-authorized-deletions.v1", task: c.task, worktree: root, paths }) + "\n";
  atomicWrite(listPath(c), bytes);
  return hash(bytes);
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  try {
    const [operation, state, task, ...args] = process.argv.slice(2);
    taskValid(task ?? "");
    if (operation === "prepare" && args.length === 2) {
      console.log(prepare({ state, task, worktree: args[0] }, args[1]));
    } else if (operation === "publish" && args.length === 1) {
      const metaPath = resolve(state, `${task}.meta`);
      const meta = readFileSync(metaPath, "utf8");
      const worktree = metaValue(meta, "worktree");
      const digest = prepare({ state, task, worktree }, args[0]);
      const lines = meta.split("\n").filter((line) => line && !line.startsWith(`${digestKey}=`));
      // Keep extension fields before pr=, whose suffix has its own grammar.
      const index = lines.findIndex((line) => line.startsWith("pr="));
      lines.splice(index < 0 ? lines.length : index, 0, `${digestKey}=${digest}`);
      atomicWrite(metaPath, lines.join("\n") + "\n");
      console.log(`task: ${JSON.stringify(task)}\nlist_sha256: ${JSON.stringify(digest)}`);
    } else throw new Error("Invalid deletion publisher invocation");
  } catch (error) {
    console.error(`fm-jev-deletions: ${error instanceof Error ? error.message : "publication failed"}`);
    process.exitCode = 1;
  }
}
