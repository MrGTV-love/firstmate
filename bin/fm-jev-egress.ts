// Deterministic worker tool coverage and outbound-call policy. No model or network
// requests occur here. docs/configuration.md "Jev guard" owns the grant contract.
import { lstatSync, readFileSync } from "node:fs";
import { resolve } from "node:path";

export type DestinationClass = "semantic-search" | "web" | "browser" | "provider" | "remote-storage";
type ToolPolicy = { result: "screen" | "unjudged" } & (
  { call: "confinement"; confinement_owner: "T5" }
  | { call: "shell" | "write" | "edit" | "local" | "paths" | "memory" | DestinationClass; confinement_owner?: never }
);

// One coverage owner for native tools and extension tools exposed as xd devices.
// "local" is an explicit unjudged classification, not an egress permission.
export const TOOL_POLICY: Readonly<Record<string, ToolPolicy>> = Object.freeze({
  bash: { call: "shell", result: "screen" },
  read: { call: "paths", result: "screen" },
  write: { call: "write", result: "unjudged" },
  edit: { call: "edit", result: "unjudged" },
  grep: { call: "paths", result: "unjudged" },
  glob: { call: "paths", result: "unjudged" },
  ast_grep: { call: "paths", result: "unjudged" },
  find: { call: "semantic-search", result: "unjudged" },
  web_search: { call: "web", result: "unjudged" },
  webfetch: { call: "web", result: "unjudged" },
  browser: { call: "browser", result: "unjudged" },
  computer: { call: "browser", result: "unjudged" },
  // T4 records ownership; T5 enforces writes at process launch, not by parsing code here.
  eval: { call: "confinement", confinement_owner: "T5", result: "unjudged" },
  python: { call: "confinement", confinement_owner: "T5", result: "unjudged" },
  ida: { call: "confinement", confinement_owner: "T5", result: "unjudged" },
  task: { call: "local", result: "unjudged" },
  generate_image: { call: "provider", result: "unjudged" },
  security_scan: { call: "provider", result: "unjudged" },
  github: { call: "remote-storage", result: "unjudged" },
  learn: { call: "memory", result: "unjudged" },
  recall: { call: "memory", result: "unjudged" },
  reflect: { call: "memory", result: "unjudged" },
  retain: { call: "memory", result: "unjudged" },
  memory_edit: { call: "memory", result: "unjudged" },
  manage_skill: { call: "confinement", confinement_owner: "T5", result: "unjudged" },
  ast_edit: { call: "confinement", confinement_owner: "T5", result: "unjudged" },
  debug: { call: "confinement", confinement_owner: "T5", result: "unjudged" },
  notebook: { call: "confinement", confinement_owner: "T5", result: "unjudged" },
  lsp: { call: "confinement", confinement_owner: "T5", result: "unjudged" },
  init_experiment: { call: "confinement", confinement_owner: "T5", result: "unjudged" },
  log_experiment: { call: "confinement", confinement_owner: "T5", result: "unjudged" },
  run_experiment: { call: "confinement", confinement_owner: "T5", result: "unjudged" },
  update_notes: { call: "local", result: "unjudged" },
  goal: { call: "local", result: "unjudged" },
  ask: { call: "local", result: "unjudged" },
  todo: { call: "local", result: "unjudged" },
  wait: { call: "local", result: "unjudged" },
  think: { call: "local", result: "unjudged" },
  yield: { call: "local", result: "unjudged" },
  checkpoint: { call: "local", result: "unjudged" },
  rewind: { call: "local", result: "unjudged" },
  context_notes: { call: "local", result: "unjudged" },
  new_context: { call: "local", result: "unjudged" },
  // Claude built-ins, lower-cased at the adapter boundary. Unknown extensions/MCP
  // names still fail coverage; these rows classify capabilities, not trusted tools.
  agent: { call: "local", result: "unjudged" },
  artifact: { call: "provider", result: "unjudged" },
  askuserquestion: { call: "local", result: "unjudged" },
  croncreate: { call: "local", result: "unjudged" },
  crondelete: { call: "local", result: "unjudged" },
  cronlist: { call: "local", result: "unjudged" },
  designsync: { call: "remote-storage", result: "unjudged" },
  endconversation: { call: "local", result: "unjudged" },
  enterplanmode: { call: "local", result: "unjudged" },
  exitplanmode: { call: "local", result: "unjudged" },
  enterworktree: { call: "confinement", confinement_owner: "T5", result: "unjudged" },
  exitworktree: { call: "confinement", confinement_owner: "T5", result: "unjudged" },
  listagents: { call: "local", result: "unjudged" },
  listmcpresourcestool: { call: "remote-storage", result: "unjudged" },
  monitor: { call: "shell", result: "unjudged" },
  notebookedit: { call: "confinement", confinement_owner: "T5", result: "unjudged" },
  powershell: { call: "shell", result: "unjudged" },
  pushnotification: { call: "provider", result: "unjudged" },
  readmcpresourcetool: { call: "remote-storage", result: "unjudged" },
  remotetrigger: { call: "provider", result: "unjudged" },
  reportfindings: { call: "local", result: "unjudged" },
  schedulewakeup: { call: "local", result: "unjudged" },
  sendmessage: { call: "local", result: "unjudged" },
  senduserfile: { call: "provider", result: "unjudged" },
  shareonboardingguide: { call: "provider", result: "unjudged" },
  skill: { call: "local", result: "unjudged" },
  structuredoutput: { call: "local", result: "unjudged" },
  subagenthandback: { call: "local", result: "unjudged" },
  taskcreate: { call: "local", result: "unjudged" },
  taskget: { call: "local", result: "unjudged" },
  tasklist: { call: "local", result: "unjudged" },
  taskoutput: { call: "local", result: "unjudged" },
  taskstop: { call: "local", result: "unjudged" },
  taskupdate: { call: "local", result: "unjudged" },
  todowrite: { call: "local", result: "unjudged" },
  toolsearch: { call: "local", result: "unjudged" },
  waitformcpservers: { call: "local", result: "unjudged" },
  workflow: { call: "local", result: "unjudged" },
  websearch: { call: "web", result: "unjudged" },
});

export function toolPolicy(name: string): ToolPolicy | undefined {
  return Object.hasOwn(TOOL_POLICY, name) ? TOOL_POLICY[name] : undefined;
}
export function uncoveredTools(names: readonly string[]): string[] {
  return [...new Set(names.filter((name) => !toolPolicy(name)))].sort();
}

const classes: Readonly<Record<string, true>> = {
  "semantic-search": true, web: true, browser: true, provider: true, "remote-storage": true,
};
function destinationClass(value: string): value is DestinationClass {
  return Object.hasOwn(classes, value);
}

/** Missing grants deny; sourceOk records readability, not authorization validity. */
export function egressGranted(state: string, task: string, destination: DestinationClass): { granted: boolean; sourceOk: boolean } {
  let sourceOk = false;
  try {
    if (!/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(task)) return { granted: false, sourceOk };
    const path = resolve(state, `${task}.meta`);
    if (!lstatSync(path).isFile()) return { granted: false, sourceOk };
    const content = readFileSync(path, "utf8");
    sourceOk = true;
    const entries = content.split("\n").filter((line) => line.startsWith("egress="));
    if (entries.length !== 1) return { granted: false, sourceOk };
    const grant: unknown = JSON.parse(entries[0].slice("egress=".length));
    if (!Array.isArray(grant) || !grant.every((entry: unknown) => typeof entry === "string" && destinationClass(entry))) return { granted: false, sourceOk };
    return { granted: grant.includes(destination), sourceOk };
  } catch { return { granted: false, sourceOk }; }
}

/** A learn call carrying a skill also writes a managed skill, so it takes manage_skill's write owner. */
export function confinementOwner(tool: string, input: unknown): "T5" | undefined {
  const policy = toolPolicy(tool === "learn" && input !== null && typeof input === "object" && (input as { skill?: unknown }).skill !== undefined ? "manage_skill" : tool);
  return policy?.call === "confinement" ? policy.confinement_owner : undefined;
}

// omp 18.12.6 github ops whose approval is "read"; every other op writes worktrees, branches, git config, refs or the remote.
const githubReadOps: Readonly<Record<string, true>> = {
  repo_view: true, file_read: true, search_issues: true, search_prs: true, search_code: true, search_commits: true, search_repos: true, run_watch: true,
};

/** A github call naming any op but a read op is refused under every grant; returns that op, JSON-encoded. */
export function refusedGithubOp(tool: string, input: unknown): string | undefined {
  if (tool !== "github") return undefined;
  const op = input !== null && typeof input === "object" ? (input as { op?: unknown }).op : undefined;
  return typeof op === "string" && Object.hasOwn(githubReadOps, op) ? undefined : JSON.stringify(op ?? null);
}

export function egressClass(tool: string): DestinationClass | undefined {
  const policy = toolPolicy(tool);
  return policy && destinationClass(policy.call) ? policy.call : undefined;
}

/**
 * The effect of one omp memory operation under the worker's live settings, as measured in
 * omp 18.12.6: every Hindsight call reaches its remote API; Mnemopi recall, reflect and
 * memory_edit read or edit the local SQLite store and embed only when mnemopi.noEmbeddings
 * is off; Mnemopi retain and learn also run model extraction unless mnemopi.llmMode is none;
 * the local backend's learn appends to a local file. Returns undefined only for a proven
 * local effect, otherwise the effect that needs a provider grant or could not be proven.
 */
export function memoryEgress(tool: string, setting: ((id: string) => unknown) | undefined): string | undefined {
  let backend: unknown, noEmbeddings: unknown, llmMode: unknown;
  try {
    if (!setting) throw new Error("no live settings");
    [backend, noEmbeddings, llmMode] = [setting("memory.backend"), setting("mnemopi.noEmbeddings"), setting("mnemopi.llmMode")];
  } catch { return "could not be proven local because the worker's live memory settings are unreadable"; }
  if (backend === "hindsight") return "makes a remote Hindsight memory call";
  if (backend === "local" && tool === "learn") return undefined;
  if (backend !== "mnemopi") return "could not be proven local because memory.backend is not mnemopi or a local-backend learn";
  if (noEmbeddings !== true) return "could not be proven local because mnemopi.noEmbeddings is not true, so it may embed through a model";
  if ((tool !== "retain" && tool !== "learn") || llmMode === "none") return undefined;
  return llmMode === "smol" || llmMode === "remote" ? `makes a Mnemopi extraction model call (mnemopi.llmMode=${llmMode})`
    : "could not be proven local because mnemopi.llmMode is not none, smol or remote";
}
