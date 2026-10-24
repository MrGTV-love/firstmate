// Installs Firstmate's worker guard using the shared ten-levels policies and
// client (bin/ten-levels/SOURCE.md) into one ship or scout worker session.
// Usage: installJevGuard(pi, {home, config, state, task, worktree, data, project, policy, noHelpers, host}) from the
// omp extension fm-spawn.sh generates, or through bin/fm-jev-guard-claude.ts.
// Firstmate's boundary and compatibility requirements are owned by
// docs/configuration.md "Jev guard"; SOURCE.md records the upstream changes.
import { egressClass, egressGranted, toolPolicy } from "./fm-jev-egress.ts";
import { realpathSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import { ContractError, type SystemOneResult } from "./ten-levels/src/core/client.ts";
import type { Questions, State } from "./ten-levels/src/core/types.ts";
import { createGuardService, failureTiming, failureType, GUARD_POLICY_VERSION, GuardUnavailableError, OUTAGE_NOTICE, OUTAGE_POLICY, SIZE_REFUSAL_NOTICE, withDecisionBudget,
  type GuardService, type GuardServiceContext, type GuardTerminal } from "./ten-levels/extensions/report.ts";
import { gateWrite, insideRepo, WRITE_QUESTIONS,
  type GateDecision } from "./ten-levels/src/levels/level06/index.ts";

export interface JevGuardContext extends GuardServiceContext {
  worktree: string;
  policy?: string;
  data: string;
  /** Native device admission belongs to the adapter, not the model service. */
  host?: "omp" | "claude";
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

// Native omp actions, not filesystem writes. Preview-only actions must stay
// previews; applying server-supplied edits/commands has no bounded target proof.
const lspEffects: Readonly<Record<string, "file-read" | "session-read" | "preview" | "file-state" | "unbounded">> = {
  references: "file-read",
  definition: "file-read",
  implementation: "file-read",
  type_definition: "file-read",
  hover: "file-read",
  symbols: "file-read",
  diagnostics: "file-read",
  capabilities: "file-read",
  status: "session-read",
  code_actions: "preview",
  rename: "preview",
  rename_file: "unbounded",
  reload: "file-state",
  request: "unbounded",
};

function plainPath(path: string): boolean {
  return /^[/A-Za-z0-9_.-]/.test(path) && !/^[A-Za-z][A-Za-z0-9+.-]*:/.test(path)
    && !path.endsWith("]");
}

function object(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

type DeviceInput = { path?: unknown; content?: unknown };
type DeviceRule = { effect: "local"; prove: (input: DeviceInput, ctx: GuardRuntimeContext, worktree: string) => boolean; remedy: string }
  | { effect: "refused"; reason: string; alternative?: (input: DeviceInput) => string | undefined }
  | { effect: "unknown"; reason: string };

function scopedLsp(input: DeviceInput, ctx: GuardRuntimeContext, worktree: string): boolean {
  if (typeof input.content !== "string" || typeof ctx.getAsyncJobSnapshot !== "function") return false;
  const args: unknown = JSON.parse(input.content);
  if (!object(args) || typeof args.action !== "string" || !Object.hasOwn(lspEffects, args.action)) return false;
  const effect = lspEffects[args.action];
  const root = realpathSync(worktree);
  if (realpathSync(ctx.cwd) !== root || effect === "unbounded") return false;
  if (effect === "session-read") return true;
  if (args.action === "symbols" && args.file === "*") return true;
  if (effect === "preview" && (args.action === "rename" ? args.apply !== false : args.apply !== undefined && args.apply !== false)) return false;
  // omp replaces these Unicode spaces before resolving the file. Diagnostics
  // also accepts globs; only an existing regular file proves a single target.
  if (typeof args.file !== "string" || !plainPath(args.file)
    || /[\u00A0\u2000-\u200A\u202F\u205F\u3000]/.test(args.file)) return false;
  const file = realpathSync(resolve(worktree, args.file));
  return statSync(file).isFile() && insideRepo(file, root);
}

function githubReadAlternative(input: DeviceInput): string | undefined {
  const args: unknown = typeof input.content === "string" ? JSON.parse(input.content) : undefined;
  if (object(args) && (args.op === "repo_view" || args.op === "file_read")) return "For this read, use gh-axi through the shell instead.";
}

function ownJob(input: DeviceInput, ctx: GuardRuntimeContext): boolean {
  const job = typeof input.path === "string" ? /^proc:\/\/([A-Za-z0-9][A-Za-z0-9._-]*)\/kill$/.exec(input.path) : null;
  if (!job || typeof ctx.getAsyncJobSnapshot !== "function") return false;
  const snapshot: unknown = ctx.getAsyncJobSnapshot();
  return object(snapshot) && Array.isArray(snapshot.running)
    && snapshot.running.some((entry: unknown) => object(entry) && entry.id === job[1]);
}

// Effects established against native omp 18.12.6 (docs/configuration.md "Jev guard").
// Device arguments are not file contents. Auto QA flushes its whole pending
// queue off the machine, and xd://github results return as unscreened write results.
const deviceEffects: Readonly<Record<string, DeviceRule>> = {
  "xd://lsp": { effect: "local", prove: scopedLsp,
    remedy: "Use a file-scoped read, a rename preview (apply: false), code-action listing (apply absent or false), or reload with a plain existing file inside this task worktree, or a workspace symbols search (file \"*\"), with the session cwd equal to that worktree. For other workspace scope, edits, commands or raw requests, report the intended action to Firstmate for effect/target review." },
  "proc://<job>/kill": { effect: "local", prove: ownJob,
    remedy: "Read proc:// to identify a running job owned by this session, then use its exact proc://<job>/kill path. Ask Firstmate to handle other tasks or shared services." },
  "xd://report_issue": { effect: "refused", reason: "Auto QA is off for firstmate workers (dev.autoqa: false in .omp/fm-worker-overlay.yml) because it uploads every pending grievance off the machine. Report the tool problem to Firstmate instead" },
  "xd://github": { effect: "refused", reason: "its results return as write-tool output, which this guard never screens for injected instructions", alternative: githubReadAlternative },
  "xd://propose": { effect: "unknown", reason: "the plan handler's downstream effects are not available to this guard" },
  "xd://resolve": { effect: "unknown", reason: "the pending apply callback's targets and downstream effects are not available to this guard" },
  "xd://reject": { effect: "unknown", reason: "the pending discard callback's targets and downstream effects are not available to this guard" },
  "xd://inspect_image": { effect: "unknown", reason: "this device is not mounted by the measured native omp installation" },
};

function deviceRule(path: string): DeviceRule | undefined {
  if (Object.hasOwn(deviceEffects, path)) return deviceEffects[path];
  if (/^proc:\/\/[A-Za-z0-9][A-Za-z0-9._-]*\/kill$/.test(path)) return deviceEffects["proc://<job>/kill"];
  if (/^(?:xd|proc):/i.test(path)) return { effect: "unknown", reason: "no measured effect is registered for this exact device" };
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

  function finishCall(terminal: GuardTerminal, reason?: string, alternative?: string): GuardCallPatch | undefined {
    const final = record(terminal);
    if (final.decision !== "block" && final.decision !== "review") return;
    const why = final.audit_error_type
      ? `Review required: AuditUnavailableError; judgment error_type=${final.error_type ?? "null"}.`
      : final.decision === "review" ? `Review required: ${final.error_type ?? "uncertain judgment"}.` : alternative ? `${reason} ${alternative}` : reason;
    const path = final.refused_path === undefined ? "" : ` Refused path: ${JSON.stringify(final.refused_path)}.`;
    const next = `${alternative && !final.audit_error_type ? "Apart from the alternative this refusal names, do" : "Do"} not retry an equivalent action through another command, tool, path or encoding. Report the refused action and reason to Firstmate and request an authorized correction or alternative.`;
    const guidance = final.error_type === "RequestTooLargeError" && !final.audit_error_type
      ? SIZE_REFUSAL_NOTICE : terminal.decision === "review" ? OUTAGE_NOTICE : next;
    return { block: true, reason: `[jev-guard] ${why}${path} ${OUTAGE_POLICY}. ${guidance}` };
  }

  pi.on("tool_call", async (event, ctx) => withDecisionBudget(async () => {
    const tool = event.toolName;
    const policy = toolPolicy(tool);
    let result: SystemOneResult | undefined;
    let trail: Trail = {};
    const terminal: GuardTerminal = { hook: "tool_call", tool, decision: "allow", enforcement: "pretool_allow",
      branch: "policy", error_type: null, request_started: false,
      ...((tool === "write" || tool === "edit") && object(event.input) && typeof event.input.path === "string"
        ? { refused_path: event.input.path } : {}) };
    if (!policy) {
      return finishCall({ ...terminal, decision: "block", enforcement: "pretool_deny", branch: "coverage" },
        "Unclassified host tool: Firstmate must classify it in fm-jev-egress.ts before execution.");
    }
    try {
      const destination = egressClass(tool);
      if (destination) {
        terminal.destination_class = destination;
        if (!egressGranted(c.state, c.task, destination)) {
          return finishCall({ ...terminal, decision: "block", enforcement: "pretool_deny", branch: "egress" },
            `Missing task egress grant: request Firstmate authorization for egress=${JSON.stringify([destination])} in state/<task>.meta. No outbound call was made.`);
        }
      }
      if (policy.call === "confinement") {
        return finishCall({ ...terminal, branch: "confinement", confinement_owner: policy.confinement_owner });
      }
      if (policy.call !== "write" && policy.call !== "edit") {
        return destination ? finishCall({ ...terminal, branch: "egress" }) : undefined;
      }
      const input = object(event.input) ? event.input : {};
      if (tool === "edit" && (typeof input.path !== "string" || typeof input.new_string !== "string")) {
        return finishCall({ ...terminal, decision: "block", enforcement: "pretool_deny", branch: "deterministic" },
          "jev-guard needs omp replace edit mode. Report this configuration problem rather than working around it.");
      }
      const path = typeof input.path === "string" ? input.path : "";
      const device = deviceRule(path);
      if (device) {
        terminal.branch = "device";
        const deny = (reason: string, alternative?: string) => finishCall({ ...terminal, decision: "block", enforcement: "pretool_deny" }, `Device ${JSON.stringify(path)} refused: ${reason}`, alternative);
        if (tool !== "write" || (c.host ?? "omp") !== "omp") return deny("native devices require omp write, not filesystem edit or a different host. Report this invocation mismatch to Firstmate.");
        if (device.effect === "unknown") return deny(`${device.reason}. Read the device documentation with read ${path} and report its installed implementation and intended effect to Firstmate so bin/fm-jev-guard.ts can register a measured rule before retrying.`);
        if (device.effect === "refused") {
          let alternative: string | undefined;
          try { alternative = device.alternative?.(input); } catch { /* Unparsed arguments name no alternative. */ }
          return deny(`${device.reason}.`, alternative);
        }
        let admitted = false;
        try { admitted = device.prove(input, ctx, c.worktree); } catch { /* Missing source or target proof fails closed. */ }
        return admitted ? finishCall(terminal) : deny(device.remedy);
      }
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
    } catch (error) {
      const error_type = failureType(error);
      const request_started = result !== undefined || (error instanceof GuardUnavailableError && error.requestStarted);
      return finishCall({ ...terminal, ...trail, decision: "review", enforcement: "pretool_deny", branch: "outage", error_type, request_started, result });
    }
  }));
}
