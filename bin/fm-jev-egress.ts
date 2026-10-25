// Deterministic worker tool coverage and outbound-call policy. No model or network
// requests occur here. docs/configuration.md "Jev guard" owns the grant contract.
import { lstatSync, readFileSync } from "node:fs";
import { resolve } from "node:path";

export type DestinationClass = "semantic-search" | "web" | "browser" | "provider" | "subagent" | "remote-storage";
type ToolPolicy = { result: "screen" | "unjudged" } & (
  { call: "confinement"; confinement_owner: "T5" }
  | { call: "shell" | "write" | "edit" | "local" | "paths" | DestinationClass; confinement_owner?: never }
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
  find: { call: "semantic-search", result: "unjudged" },
  web_search: { call: "web", result: "unjudged" },
  webfetch: { call: "web", result: "unjudged" },
  browser: { call: "browser", result: "unjudged" },
  computer: { call: "browser", result: "unjudged" },
  // T4 records ownership; T5 enforces writes at process launch, not by parsing code here.
  eval: { call: "confinement", confinement_owner: "T5", result: "unjudged" },
  python: { call: "confinement", confinement_owner: "T5", result: "unjudged" },
  task: { call: "subagent", result: "unjudged" },
  generate_image: { call: "provider", result: "unjudged" },
  security_scan: { call: "provider", result: "unjudged" },
  learn: { call: "provider", result: "unjudged" },
  recall: { call: "provider", result: "unjudged" },
  reflect: { call: "provider", result: "unjudged" },
  retain: { call: "provider", result: "unjudged" },
  memory_edit: { call: "local", result: "unjudged" },
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
  // Claude built-ins, lower-cased at the adapter boundary. Unknown extensions/MCP
  // names still fail coverage; these rows classify capabilities, not trusted tools.
  agent: { call: "subagent", result: "unjudged" },
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
  sendmessage: { call: "subagent", result: "unjudged" },
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
  workflow: { call: "subagent", result: "unjudged" },
  websearch: { call: "web", result: "unjudged" },
});

export function toolPolicy(name: string): ToolPolicy | undefined {
  return Object.hasOwn(TOOL_POLICY, name) ? TOOL_POLICY[name] : undefined;
}
export function uncoveredTools(names: readonly string[]): string[] {
  return [...new Set(names.filter((name) => !toolPolicy(name)))].sort();
}

const classes: Readonly<Record<string, true>> = {
  "semantic-search": true, web: true, browser: true, provider: true, subagent: true, "remote-storage": true,
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

export function egressClass(tool: string): DestinationClass | undefined {
  const policy = toolPolicy(tool);
  return policy && destinationClass(policy.call) ? policy.call : undefined;
}
