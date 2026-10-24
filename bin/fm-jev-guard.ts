// Installs Firstmate's worker guard using the shared ten-levels policies and
// client (bin/ten-levels/SOURCE.md) into one ship or scout worker session.
// Usage: installJevGuard(pi, {home, config, state, task, worktree, data, project, policy, noHelpers}) from the
// omp extension fm-spawn.sh generates, or through bin/fm-jev-guard-claude.ts.
// Firstmate's boundary and compatibility requirements are owned by
// docs/configuration.md "Jev guard"; SOURCE.md records the upstream changes.
import { readFileSync, realpathSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import { ContractError, type SystemOneResult } from "./ten-levels/src/core/client.ts";
import type { Questions, State } from "./ten-levels/src/core/types.ts";
import { createGuardService, failureTiming, failureType, GUARD_POLICY_VERSION, GuardUnavailableError, OUTAGE_NOTICE, OUTAGE_POLICY, SIZE_REFUSAL_NOTICE, withDecisionBudget,
  type GuardService, type GuardServiceContext, type GuardTerminal } from "./ten-levels/extensions/report.ts";
import { BASH_QUESTIONS, gateBash, gateWrite, insideRepo, WRITE_QUESTIONS,
  type GateDecision } from "./ten-levels/src/levels/level06/index.ts";

export interface JevGuardContext extends GuardServiceContext {
  worktree: string;
  policy?: string;
  data: string;
}

export interface GuardRuntimeContext {
  cwd: string;
  getAsyncJobSnapshot?: () => unknown;
}
export interface GuardCallEvent {
  toolName: string;
  toolCallId?: string;
  input?: unknown;
}
export interface GuardCallPatch { block: true; reason: string }
export type GuardCallHandler = (event: GuardCallEvent, ctx: GuardRuntimeContext) => Promise<GuardCallPatch | void>;
export interface GuardHost {
  on(name: "tool_call", handler: GuardCallHandler): void;
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
      // omp's path resolver replaces these Unicode spaces before resolving the file.
      // Reject rewritten spellings so the realpath check sees the execution target.
      if (!plainPath(args.file) || /[\u00A0\u2000-\u200A\u202F\u205F\u3000]/.test(args.file)) return false;
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

type Judge = (state: State, questions: Questions) => Promise<SystemOneResult>;
type Gated = GateDecision & { risk: number };
type Trail = Pick<GuardTerminal, "chunks" | "results" | "failures">;
/** One piece of a payload: its policy judgment, or why it could not be judged. Either way it keeps any answer it received. */
type Part<D> = { result?: SystemOneResult } & ({ decision: D } | { failure: unknown });
type Settled<D> = { result?: SystemOneResult; trail: Trail } & ({ decision: D; part: number; of: number } | { failure: unknown });

/** Judges every piece to the end, so one piece that cannot be screened never hides a verdict on another. */
function screenParts<D>(pieces: string[], run: (piece: string, judge: Judge) => Promise<D>, service: GuardService): Promise<Part<D>[]> {
  return Promise.all(pieces.map(async (piece): Promise<Part<D>> => {
    let result: SystemOneResult | undefined;
    try {
      const decision = await run(piece, async (state, questions) => (result = await service.decide(state, questions)));
      return { result, decision };
    } catch (failure) {
      return { result, failure };
    }
  }));
}

/**
 * The verdict for the whole payload. The first piece that `stops` it decides; otherwise a piece that could not be screened does;
 * otherwise every piece passed and the riskiest one is the record. A payload is never passed on the strength of some of its pieces.
 */
function settle<D>(parts: Part<D>[], stops: (decision: D) => boolean, risk: (decision: D) => number): Settled<D> {
  const results = parts.flatMap((part) => part.result ?? []);
  const failures = parts.flatMap((part, index) => "failure" in part && !part.result ? [{
    chunk: index + 1, error_type: failureType(part.failure),
    request_started: part.failure instanceof GuardUnavailableError && part.failure.requestStarted,
    ...failureTiming(part.failure),
  }] : []);
  const trail: Trail = { chunks: parts.filter((part) => part.result || "failure" in part).length, results, failures };
  const judged = parts.flatMap((part, index) => ("decision" in part ? [{ part: index, result: part.result, decision: part.decision }] : []));
  const stopped = judged.find((piece) => stops(piece.decision));
  if (stopped) return { ...stopped, of: parts.length, trail };
  const bad = parts.find((part) => "failure" in part);
  if (bad && "failure" in bad) return { result: bad.result ?? results[0], failure: bad.failure, trail };
  const top = judged.reduce((best, piece) => (risk(piece.decision) > risk(best.decision) ? piece : best));
  return { ...top, of: parts.length, trail };
}

/** A multi-piece block names its piece, so the worker can find the part that was refused. */
function whereBlocked(settled: { part: number; of: number }, reason: string): string {
  return settled.of > 1 ? `${reason} (part ${settled.part + 1} of ${settled.of})` : reason;
}

/** Anchored, low false-positive shapes only, not semantic secret detection; scan the whole budget-limited write before egress. */
function credentialShaped(content: string): boolean {
  return /-----BEGIN (?:[A-Z0-9]+ )?PRIVATE KEY(?: BLOCK)?-----/.test(content)
    || /(?<![A-Za-z0-9_-])(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|(?:AKIA|ASIA)[A-Z0-9]{16}|xox[baprs]-[A-Za-z0-9-]{16,})/.test(content)
    // Consume each complete scheme-character run, including punctuation-led runs, without restarting at hyphens.
    || /(?<![a-z0-9+.-])[a-z0-9+.-]+:\/\/[^\s/:@?#"'`<>()\[\]{}\\,;|]*:[^\s/@?#"'`<>()\[\]{}\\,;|]{8,}@/i.test(content);
}

// A disposable lab home is not a production fleet. Its marker is written by
// bin/fm-lab-home.sh and carries the same token bin/fm-gate-refuse-lib.sh reads;
// like fm_gate_lab_permitted, the home counts as a lab only while every
// FM_*_OVERRIDE is empty, so no override can split the call onto a real fleet.
// The guard consults it only when a shell judgment could not run, so an
// approved lab teardown is not refused by an unavailable judge.
const LAB_MARKER = ".fm-lab-home";
const LAB_TOKEN = "fm-lab-home v1";

function labPermitted(home: string): boolean {
  if (Object.entries(process.env).some(([name, value]) => /^FM_.*_OVERRIDE$/.test(name) && value)) return false;
  try {
    return readFileSync(resolve(home, LAB_MARKER), "utf8").split("\n")[0] === LAB_TOKEN;
  } catch {
    return false;
  }
}

// Read-only shell commands have no effect to judge, so an unavailable judge
// must never refuse a directory listing, a process check or a repository
// inspection. The test is deliberately conservative: any redirection,
// substitution, expansion, quoting, sequencing or background operator
// disqualifies the command, every pipeline segment must itself be a read-only
// program, and options that write or execute disqualify it. Outside the lab
// admission, anything not proven read-only is refused on an outage as before.
const READ_ONLY_PROGRAMS = new Set([
  "ls", "cat", "head", "tail", "wc", "stat", "du", "df", "pwd", "echo", "printf",
  "grep", "egrep", "fgrep", "ps", "pgrep", "uname", "id", "whoami",
  "which", "type", "uptime", "lsof", "cut", "basename", "dirname",
  "realpath", "readlink", "jq", "true", "false",
]);
const READ_ONLY_GIT = new Set(["status", "log", "diff", "show", "rev-parse", "ls-files", "describe", "blame", "shortlog"]);
const SHELL_MUTATION = /[<>`$'"\\*?[{}]|\n|;|&&|\|\||&/;

function outputOption(token: string): boolean {
  const name = token.split("=")[0];
  return name.length > 2 && (name.startsWith("--output") || "--output".startsWith(name));
}

function readOnlyShell(command: string): boolean {
  const text = command.trim();
  if (text === "" || SHELL_MUTATION.test(text)) return false;
  for (const segment of text.split("|")) {
    const tokens = segment.trim().split(/\s+/).filter(Boolean);
    if (tokens.length === 0 || tokens.some(outputOption)) return false;
    const program = tokens[0];
    if (program === "git") {
      let sub = 1;
      while (tokens[sub] === "--no-pager") sub++;
      if (!READ_ONLY_GIT.has(tokens[sub] ?? "")) return false;
      continue;
    }
    if (program === "find") {
      if (tokens.some((token) => /^-(exec|execdir|ok|okdir|delete|fprint|fprint0|fprintf|fls)$/.test(token))) return false;
      continue;
    }
    if (!READ_ONLY_PROGRAMS.has(program)) return false;
  }
  return true;
}

export function installJevGuard(pi: GuardHost, c: JevGuardContext): void {
  if (c.policy !== GUARD_POLICY_VERSION) return;
  // Set before native LSP startup; this is process-local, never a profile setting.
  process.env.PI_DISABLE_LSPMUX = "1";
  const service = createGuardService(c);
  const roots = [...new Set([c.worktree, ...real(c.data), ...real(tmpdir()), ...real("/tmp")])];

  function record(terminal: GuardTerminal): GuardTerminal & { audit_error_type?: "AuditUnavailableError" } {
    try {
      service.record(terminal);
      return terminal;
    } catch {
      if (!service.active) return terminal;
      return { ...terminal, decision: "review", branch: "outage", audit_error_type: "AuditUnavailableError",
        enforcement: "pretool_deny" };
    }
  }

  function finishCall(terminal: GuardTerminal, reason?: string): GuardCallPatch | undefined {
    const final = record(terminal);
    if (final.decision !== "block" && final.decision !== "review") return;
    const why = final.audit_error_type
      ? `Review required: AuditUnavailableError; judgment error_type=${final.error_type ?? "null"}.`
      : final.decision === "review" ? `Review required: ${final.error_type ?? "uncertain judgment"}.` : reason;
    const path = final.refused_path === undefined ? "" : ` Refused path: ${JSON.stringify(final.refused_path)}.`;
    const next = "Do not retry an equivalent action through another command, tool, path or encoding. Report the refused action and reason to Firstmate and request an authorized correction or alternative.";
    const guidance = final.error_type === "RequestTooLargeError" && !final.audit_error_type
      ? SIZE_REFUSAL_NOTICE : terminal.decision === "review" ? OUTAGE_NOTICE : next;
    return { block: true, reason: `[jev-guard] ${why}${path} ${OUTAGE_POLICY}. ${guidance}` };
  }

  pi.on("tool_call", async (event, ctx) => withDecisionBudget(async () => {
    const tool = event.toolName;
    if (tool !== "bash" && tool !== "write" && tool !== "edit") return;
    let result: SystemOneResult | undefined;
    let trail: Trail = {};
    const terminal: GuardTerminal = { hook: "tool_call", tool, decision: "allow", enforcement: "pretool_allow",
      branch: "policy", error_type: null, request_started: false,
      ...((tool === "write" || tool === "edit") && object(event.input) && typeof event.input.path === "string"
        ? { refused_path: event.input.path } : {}) };
    try {
      const input = object(event.input) ? event.input : {};
      if (tool === "edit" && (typeof input.path !== "string" || typeof input.new_string !== "string")) {
        return finishCall({ ...terminal, decision: "block", enforcement: "pretool_deny", branch: "deterministic" },
          "jev-guard needs omp replace edit mode. Report this configuration problem rather than working around it.");
      }
      if (tool === "write" || tool === "edit") {
        if (tool === "write" && admittedDevice(input, ctx, c.worktree)) return finishCall({ ...terminal, branch: "device" });
        const path = typeof input.path === "string" ? input.path : "";
        if (!plainPath(path)) {
          return finishCall({ ...terminal, decision: "block", enforcement: "pretool_deny", branch: "deterministic" },
            "jev-guard needs a plain absolute or worktree-relative path. Use one, and report if that is not possible rather than working around this block.");
        }
        const repo = roots.find((root) => insideRepo(path, root));
        if (!repo) return finishCall({ ...terminal, decision: "block", enforcement: "pretool_deny", branch: "deterministic" }, `outside the repo: ${path}`);
        if (!service.active) return finishCall({ ...terminal, decision: "inactive", enforcement: "inactive_no_protection", branch: "inactive" });
        const content = tool === "edit" ? input.new_string : input.content;
        if (typeof content !== "string") throw new GuardUnavailableError("InvalidToolInputError");
        const { pieces, ...coverage } = service.planWrite({ path, content }, WRITE_QUESTIONS);
        if (coverage.local_only_bytes > 0 && credentialShaped(content)) {
          return finishCall({ ...terminal, decision: "block", enforcement: "pretool_deny", branch: "deterministic" },
            "contains a credential-shaped value: the whole write was checked locally; no content was sent for model screening");
        }
        const settled = settle(await screenParts(pieces, async (piece, judge) => {
          const { kind, contains_secret } = (await judge({ path, content: piece }, WRITE_QUESTIONS)).answers;
          if (kind?.type !== "choice" || contains_secret?.type !== "noul") throw new ContractError("Invalid write answers.");
          return { ...gateWrite({ kind, contains_secret }), risk: contains_secret.noul };
        }, service), (decision: Gated) => decision.block, (decision) => decision.risk);
        ({ result, trail } = settled);
        if ("failure" in settled) throw settled.failure;
        return finishCall({ ...terminal, ...trail, decision: settled.decision.block ? "block" : "allow",
          ...(!settled.decision.block ? { write_coverage: coverage } : {}),
          enforcement: settled.decision.block ? "pretool_deny" : "pretool_allow", request_started: true, result }, whereBlocked(settled, settled.decision.reason));
      }
      if (!service.active) return finishCall({ ...terminal, decision: "inactive", enforcement: "inactive_no_protection", branch: "inactive" });
      if (typeof input.command !== "string") throw new GuardUnavailableError("InvalidToolInputError");
      const settled = settle(await screenParts(service.plan({ command: input.command, cwd: ctx.cwd }, "command", BASH_QUESTIONS), async (piece, judge) => {
        const { effect, destructive_intent } = (await judge({ command: piece, cwd: ctx.cwd }, BASH_QUESTIONS)).answers;
        if (effect?.type !== "choice" || destructive_intent?.type !== "noul") throw new ContractError("Invalid shell answers.");
        return { ...gateBash({ effect, destructive_intent }), risk: destructive_intent.noul };
      }, service), (decision: Gated) => decision.block, (decision) => decision.risk);
      ({ result, trail } = settled);
      if ("failure" in settled) throw settled.failure;
      return finishCall({ ...terminal, ...trail, decision: settled.decision.block ? "block" : "allow",
        enforcement: settled.decision.block ? "pretool_deny" : "pretool_allow", request_started: true, result }, whereBlocked(settled, settled.decision.reason));
    } catch (error) {
      const error_type = failureType(error);
      const request_started = result !== undefined || (error instanceof GuardUnavailableError && error.requestStarted);
      const command = tool === "bash" && error_type !== "RequestTooLargeError" && object(event.input) ? event.input.command : undefined;
      const admitted = typeof command !== "string" ? undefined : readOnlyShell(command) ? "read_only" : labPermitted(c.home) ? "lab" : undefined;
      if (admitted) return finishCall({ ...terminal, ...trail, branch: admitted, error_type, request_started, result });
      return finishCall({ ...terminal, ...trail, decision: "review", enforcement: "pretool_deny", branch: "outage", error_type, request_started, result });
    }
  }));

}
