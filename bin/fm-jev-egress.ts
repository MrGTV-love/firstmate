// Deterministic worker tool coverage and outbound-call policy. No model or network
// requests occur here. docs/configuration.md "Jev guard" owns the grant contract.
import { lstatSync, readFileSync, realpathSync } from "node:fs";
import { dirname, resolve } from "node:path";

export type DestinationClass = "semantic-search" | "web" | "browser" | "remote-shell" | "github"
  | "package-registry" | "provider" | "subagent" | "dynamic-code" | "remote-storage" | "telemetry";
export interface EgressShape { destination_class: DestinationClass; argv_shape: string }
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
  "xd://report_issue": { call: "telemetry", result: "unjudged" },
  python: { call: "dynamic-code", result: "unjudged" },
  task: { call: "subagent", result: "unjudged" },
  generate_image: { call: "provider", result: "unjudged" },
  security_scan: { call: "provider", result: "unjudged" },
  learn: { call: "provider", result: "unjudged" },
  recall: { call: "provider", result: "unjudged" },
  reflect: { call: "provider", result: "unjudged" },
  retain: { call: "provider", result: "unjudged" },
  memory_edit: { call: "local", result: "unjudged" },
  manage_skill: { call: "local", result: "unjudged" },
  ast_edit: { call: "local", result: "unjudged" },
  debug: { call: "dynamic-code", result: "unjudged" },
  notebook: { call: "local", result: "unjudged" },
  lsp: { call: "local", result: "unjudged" },
  init_experiment: { call: "local", result: "unjudged" },
  log_experiment: { call: "local", result: "unjudged" },
  run_experiment: { call: "dynamic-code", result: "unjudged" },
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
  endconversation: { call: "local", result: "unjudged" },
  enterplanmode: { call: "local", result: "unjudged" },
  exitplanmode: { call: "local", result: "unjudged" },
  enterworktree: { call: "confinement", confinement_owner: "T5", result: "unjudged" },
  exitworktree: { call: "confinement", confinement_owner: "T5", result: "unjudged" },
  listagents: { call: "remote-storage", result: "unjudged" },
  listmcpresourcestool: { call: "remote-storage", result: "unjudged" },
  monitor: { call: "dynamic-code", result: "unjudged" },
  multiedit: { call: "confinement", confinement_owner: "T5", result: "unjudged" },
  notebookedit: { call: "confinement", confinement_owner: "T5", result: "unjudged" },
  powershell: { call: "dynamic-code", result: "unjudged" },
  pushnotification: { call: "provider", result: "unjudged" },
  readmcpresourcetool: { call: "remote-storage", result: "unjudged" },
  remotetrigger: { call: "provider", result: "unjudged" },
  reportfindings: { call: "local", result: "unjudged" },
  schedulewakeup: { call: "local", result: "unjudged" },
  sendfeedback: { call: "local", result: "unjudged" },
  sendmessage: { call: "subagent", result: "unjudged" },
  senduserfile: { call: "provider", result: "unjudged" },
  shareonboardingguide: { call: "provider", result: "unjudged" },
  skill: { call: "confinement", confinement_owner: "T5", result: "unjudged" },
  subagenthandback: { call: "subagent", result: "unjudged" },
  taskcreate: { call: "local", result: "unjudged" },
  taskget: { call: "local", result: "unjudged" },
  tasklist: { call: "local", result: "unjudged" },
  taskoutput: { call: "local", result: "unjudged" },
  taskstop: { call: "confinement", confinement_owner: "T5", result: "unjudged" },
  taskupdate: { call: "local", result: "unjudged" },
  todowrite: { call: "local", result: "unjudged" },
  toolsearch: { call: "local", result: "unjudged" },
  waitformcpservers: { call: "remote-storage", result: "unjudged" },
  workflow: { call: "subagent", result: "unjudged" },
  websearch: { call: "web", result: "unjudged" },
});

export function toolPolicy(name: string): ToolPolicy | undefined {
  return Object.hasOwn(TOOL_POLICY, name) ? TOOL_POLICY[name] : undefined;
}
/** A device exposed through write is still a tool invocation, not a file write. */
export function callPolicy(tool: string, input: unknown): ToolPolicy | undefined {
  if (tool === "write" && object(input) && typeof input.path === "string" && input.path.startsWith("xd://")) {
    const device = toolPolicy(input.path);
    if (device) return device;
  }
  return toolPolicy(tool);
}
export function uncoveredTools(names: readonly string[]): string[] {
  return [...new Set(names.filter((name) => !toolPolicy(name)))].sort();
}

const classes: Readonly<Record<string, true>> = {
  "semantic-search": true, web: true, browser: true, "remote-shell": true, github: true,
  "package-registry": true, provider: true, subagent: true, "dynamic-code": true, "remote-storage": true, telemetry: true,
};
function destinationClass(value: string): value is DestinationClass {
  return Object.hasOwn(classes, value);
}

/** Missing grants deny; malformed, duplicate, unreadable or symlinked records never grant. */
export function egressGranted(state: string, task: string, shapes: readonly EgressShape[]): boolean {
  try {
    if (!/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(task)) return false;
    const path = resolve(state, `${task}.meta`);
    if (!lstatSync(path).isFile() || realpathSync(dirname(path)) !== realpathSync(state)) return false;
    const entries = readFileSync(path, "utf8").split("\n").filter((line) => line.startsWith("egress="));
    if (entries.length !== 1) return false;
    const grant: unknown = JSON.parse(entries[0].slice("egress=".length));
    if (!Array.isArray(grant) || !grant.every((entry: unknown) => typeof entry === "string" && destinationClass(entry))) return false;
    return shapes.every((shape) => grant.includes(shape.destination_class));
  } catch { return false; }
}

const programs: Readonly<Record<string, DestinationClass>> = Object.freeze({
  curl: "web", wget: "web", ssh: "remote-shell", scp: "remote-shell", sftp: "remote-shell", rsync: "remote-shell",
  gh: "github", "gh-axi": "github", "chrome-devtools-axi": "browser",
});
const packages: Readonly<Record<string, Readonly<Record<string, true>>>> = Object.freeze({
  npm: { install: true, i: true, ci: true, update: true, add: true, exec: true, publish: true, view: true, search: true },
  pnpm: { install: true, i: true, add: true, update: true, dlx: true, publish: true, view: true },
  yarn: { install: true, add: true, up: true, dlx: true, npm: true },
  bun: { install: true, i: true, add: true, update: true, x: true, publish: true },
  pip: { install: true, download: true, index: true }, pip3: { install: true, download: true, index: true },
  uv: { add: true, sync: true, pip: true, tool: true, run: true },
  brew: { install: true, upgrade: true, update: true, fetch: true, tap: true },
});

// Normalize literal shell words, including quoted/escaped command names. This
// is an entry-point detector, not a shell interpreter or a network sandbox.
function shellWords(command: string): string[] {
  const words: string[] = [];
  let word = "";
  let quote = "";
  for (let i = 0; i < command.length; i++) {
    const ch = command[i];
    if (ch === "\\" && quote !== "'" && i + 1 < command.length) { word += command[++i]; continue; }
    if (quote) { if (ch === quote) quote = ""; else word += ch; continue; }
    if (ch === "'" || ch === '"') { quote = ch; continue; }
    if (/\s|[;|&()<>`]/.test(ch)) {
      if (word) words.push(word);
      word = "";
      if (/[;|&()<>`\n]/.test(ch)) words.push(";");
      continue;
    }
    word += ch;
  }
  if (word) words.push(word);
  return words;
}

function shellEgress(command: string): EgressShape[] {
  const shapes: EgressShape[] = [];
  const add = (destination_class: DestinationClass, argv_shape: string): void => {
    if (!shapes.some((shape) => shape.destination_class === destination_class && shape.argv_shape === argv_shape)) {
      shapes.push({ destination_class, argv_shape });
    }
  };
  const words = shellWords(command);
  let executable = true;
  let wrapped = false;
  for (let i = 0; i < words.length; i++) {
    if (words[i] === ";") { executable = true; wrapped = false; continue; }
    if (executable && /^[A-Za-z_][A-Za-z0-9_]*=/.test(words[i])) continue;
    if (!executable && !wrapped) continue;
    const program = words[i].slice(words[i].lastIndexOf("/") + 1);
    if (["env", "command", "exec", "sudo", "nohup", "time", "timeout", "nice"].includes(program)) { wrapped = true; continue; }
    executable = false;
    if (Object.hasOwn(programs, program)) add(programs[program], program);
    if (program === "npx" || program === "bunx") add("package-registry", program);
    let end = i + 1;
    while (end < words.length && words[end] !== ";") end++;
    const args = words.slice(i + 1, end);
    if (program === "no-mistakes" && args[0] === "axi" && ["run", "respond"].includes(args[1])) add("provider", "pipeline-drive");
    if (["claude", "omp", "pi"].includes(program) && args.some((arg) => ["-p", "--print"].includes(arg))) add("provider", "model-prompt");
    if (program === "codex" && args[0] === "exec") add("provider", "model-prompt");
    if (Object.hasOwn(packages, program) && args.some((word) => Object.hasOwn(packages[program], word))) add("package-registry", program);
    if (["python", "python3"].includes(program) && args[0] === "-m" && args[1] === "pip"
      && args.slice(2).some((word) => Object.hasOwn(packages.pip, word))) add("package-registry", "pip");
    if (program === "git" && args.some((word) => ["fetch", "pull", "push", "clone", "ls-remote"].includes(word))) add("remote-storage", "git-remote");
    // Quoted interpreter argv can contain shell entry points too.
    if (["sh", "bash", "zsh"].includes(program) && args[0]?.startsWith("-") && args[0].includes("c") && args[1]) {
      for (const shape of shellEgress(args[1])) add(shape.destination_class, shape.argv_shape);
    }
    // Other inline code is opaque to this detector and needs an execution grant.
    if (["eval", "python", "python3", "node", "bun"].includes(program)
      && (program === "eval" || args.some((arg) => ["-c", "-e", "--eval", "--print"].includes(arg)))) add("dynamic-code", "inline-code");
  }
  if (shapes.length === 0 && /(?:https?|wss?|ssh|sftp|ftp):\/\/|\b[A-Za-z0-9_.-]+@[A-Za-z0-9_.-]+:/.test(command)) add("provider", "endpoint");
  return shapes;
}

function object(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

export function callEgress(tool: string, input: unknown): EgressShape[] {
  const policy = callPolicy(tool, input);
  if (!policy) return [];
  if (policy.call === "confinement") return [];
  if (tool === "write" && object(input) && typeof input.path === "string" && input.path.startsWith("xd://")
    && destinationClass(policy.call)) return [{ destination_class: policy.call, argv_shape: "path" }];
  const args = object(input) ? input : {};
  if (policy.call === "shell") return typeof args.command === "string" ? shellEgress(args.command) : [];
  if (policy.call === "paths" || policy.call === "write" || policy.call === "edit") {
    const values = [args.path, args.file_path].filter((v): v is string => typeof v === "string");
    const shapes: EgressShape[] = [];
    for (const value of values) {
      for (const path of value.split(";")) {
        let destination_class: DestinationClass | undefined;
        if (/^https?:\/\//i.test(path)) destination_class = "web";
        else if (/^ssh:\/\//i.test(path)) destination_class = "remote-shell";
        else if (/^(?:pr|issue):\/\//i.test(path)) destination_class = "github";
        else if (/^mcp:\/\//i.test(path)) destination_class = "remote-storage";
        else if (tool === "write" && path.startsWith("xd://")) {
          const device = path.slice(5);
          const devicePolicy = toolPolicy(device);
          if (devicePolicy && destinationClass(devicePolicy.call)) destination_class = devicePolicy.call;
        }
        if (destination_class && !shapes.some((s) => s.destination_class === destination_class)) shapes.push({ destination_class, argv_shape: "path" });
      }
    }
    return shapes;
  }
  if (policy.call === "local") return [];
  return [{ destination_class: policy.call, argv_shape: "native" }];
}
