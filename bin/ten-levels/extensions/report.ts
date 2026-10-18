/** Firstmate's bounded Jev service and minimized audit owner; see docs/configuration.md. */
import { AsyncLocalStorage } from "node:async_hooks";
import { Buffer } from "node:buffer";
import { execFileSync } from "node:child_process";
import { appendFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { setTimeout as sleep } from "node:timers/promises";
import { ContractError, JevClient, type SystemOneResult } from "../src/core/client.ts";
import { QuestionValidationError, validateRequest, type Questions, type State } from "../src/core/types.ts";
import { BASH_THRESHOLDS, SCREEN_THRESHOLDS, WRITE_THRESHOLDS } from "../src/levels/level06/index.ts";

export const GUARD_POLICY_VERSION = "FIRSTMATE_JEV_GUARD_V1";
export const OUTAGE_POLICY = "REVIEW_ON_UNAVAILABLE_V1";
export const GUARD_MODEL = "jev-1.13.0";
export const MAX_REQUEST_BYTES = 16_384;
/** A payload over the ceiling is screened as overlapping pieces, each one a complete request that fits it. */
export const MAX_CHUNKS = 16;
/** A span up to 1,000 JSON-escaped bytes always lies whole inside one piece; a longer one can be cut, and each half is still screened. */
export const CHUNK_OVERLAP_BYTES = 1_024;
/** Presentation only: these are the existing screening limits, not a new admission rule. */
export const SIZE_REFUSAL_NOTICE = `REFUSED: guard=FM-JEV-SIZE rule=complete-screening-budget missing=complete payload coverage within ${MAX_CHUNKS} requests of ${MAX_REQUEST_BYTES} UTF-8 bytes each, including model, questions and JSON framing, with ${CHUNK_OVERLAP_BYTES} JSON-escaped bytes of overlap. `
  + `The ${MAX_CHUNKS * MAX_REQUEST_BYTES}-character coarse precheck is not a usable content budget: UTF-8, escaping, framing and overlap also consume room. `
  + "Supported completing route for report writes: use the same write tool to split the report across separate files, each below 150,000 characters per write, and smaller again if encoded bytes still exceed the screening budget. Every write must fit and is screened completely. "
  + "This is size-budget compliance only, not permission to split or reroute a prohibited action. For a shell call or unsplittable operation, human-only-exit: what authorized smaller operation preserves the intended effect within this budget?";
/** Outage-only deny guidance; the worker adapter owns policy-refusal next steps. */
export const OUTAGE_NOTICE = "The review could not run, so this is not a verdict on the call. You may run the same call once more. "
  + "If it fails the same way, stop and tell the user; do not work around it with another command, tool, path or encoding.";

interface Budget { tryMs: number; tries: number; decisionMs: number; backoffMs: number; reserveWholeTry: boolean }
// The per-try limit guards only against a judge that never answers; answered calls are far faster
// (p99 535 ms over 15,640 calls, docs/configuration.md "Unreachable threshold").
const WIDE_BUDGET: Budget = { tryMs: 90_000, tries: 3, decisionMs: 300_000, backoffMs: 1_000, reserveWholeTry: true };
// omp 18.12.0 forwards the original output when its nonconfigurable 30-second tool_result deadline passes.
// Its tool_call deadline (extensionHandlers.toolCallTimeoutMs) is raised past WIDE_BUDGET by .omp/fm-worker-overlay.yml.
const OMP_RESULT_BUDGET: Budget = { tryMs: 12_000, tries: 2, decisionMs: 25_000, backoffMs: 500, reserveWholeTry: false };
const budgetFor = (hook: GuardTerminal["hook"], host: "omp" | "claude"): Budget => host === "omp" && hook === "tool_result" ? OMP_RESULT_BUDGET : WIDE_BUDGET;
const RETRYABLE_FAILURES: ReadonlySet<GuardFailureType> = new Set(["TimeoutError", "TypeError", "Error"]);
const lib = resolve(dirname(fileURLToPath(import.meta.url)), "../../fm-typesafe-lib.sh");
const budgets = new AsyncLocalStorage<{ until: number; signal: AbortSignal; budget: Budget }>();

export type GuardFailureType = "ContractError" | "QuestionValidationError" | "TimeoutError" | "AbortError"
  | "TypeError" | "Error" | "PrivacyWithheldError" | "CredentialUnavailableError" | "RequestTooLargeError"
  | "AuditUnavailableError" | "InvalidToolInputError" | "UnsupportedToolResultError"
  | "InactiveGuardError";

export class GuardUnavailableError extends Error {
  readonly errorType: GuardFailureType;
  readonly requestStarted: boolean;
  /** Provider tries and elapsed time; null when no request started. */
  readonly attempts: number | null;
  readonly elapsedMs: number | null;
  constructor(errorType: GuardFailureType, requestStarted = false, cause?: unknown, timing?: { attempts: number; elapsedMs: number }) {
    super("Jev guard requires review.", { cause });
    this.name = errorType;
    this.errorType = errorType;
    this.requestStarted = requestStarted;
    this.attempts = timing?.attempts ?? null;
    this.elapsedMs = timing?.elapsedMs ?? null;
  }
}

/** Failure rows carry the guard's own try count and elapsed time, so a timeout can be told from an error. */
export function failureTiming(error: unknown): { attempts: number | null; ms: number | null } {
  return error instanceof GuardUnavailableError ? { attempts: error.attempts, ms: error.elapsedMs } : { attempts: null, ms: null };
}

const sum = (values: number[]): number => values.reduce((total, value) => total + value, 0);

/** A piecewise total is a reported charge only when every piece reported one. */
function totalCost(results: SystemOneResult[]): SystemOneResult["meta"]["cost"] {
  const costs = results.map((r) => r.meta.cost);
  return costs.every((cost) => cost.amount !== null && cost.source === "reported")
    ? { amount: sum(costs.map((cost) => cost.amount ?? 0)), source: "reported" } : { amount: null, source: "unknown" };
}

/** Preserve known original types without copying exception text or arbitrary exception names. */
export function failureType(error: unknown): GuardFailureType {
  if (error instanceof GuardUnavailableError) return error.errorType;
  if (error instanceof ContractError) return "ContractError";
  if (error instanceof QuestionValidationError) return "QuestionValidationError";
  if (error instanceof DOMException && (error.name === "TimeoutError" || error.name === "AbortError")) return error.name;
  return error instanceof TypeError ? "TypeError" : "Error";
}

export interface GuardServiceContext {
  home: string;
  config: string;
  state: string;
  task: string;
  project?: string;
  noHelpers?: boolean;
  host?: "omp" | "claude";
}

export interface GuardTerminal {
  hook: "tool_call" | "tool_result";
  tool: "bash" | "read" | "write" | "edit";
  decision: "allow" | "block" | "clear" | "flag" | "review" | "inactive";
  enforcement: "pretool_allow" | "pretool_deny" | "result_pass" | "omp_replace"
    | "claude_advisory_only" | "inactive_no_protection";
  branch: "policy" | "deterministic" | "device" | "empty" | "outage" | "inactive" | "supervisor_consistency" | "trusted_read";
  /** Only refused write/edit paths; never command text or content. */
  refused_path?: string;
  error_type: GuardFailureType | null;
  request_started: boolean;
  result?: SystemOneResult;
  /** Planned pieces, every answered piece, and minimized timing for every unanswered piece. */
  chunks?: number;
  results?: SystemOneResult[];
  failures?: { chunk: number; error_type: GuardFailureType; request_started: boolean; attempts: number | null; ms: number | null }[];
}

export interface GuardService {
  readonly active: boolean;
  readonly host: "omp" | "claude";
  decide(state: State, questions: Questions): Promise<SystemOneResult>;
  /**
   * The text of `state[field]` as the pieces to screen: itself when the whole request fits the ceiling, otherwise
   * overlapping pieces that each fit it. Refuses before any egress when the payload cannot be covered completely.
   */
  plan(state: Record<string, unknown>, field: string, questions: Questions): string[];
  record(terminal: GuardTerminal): void;
}

export async function withDecisionBudget<T>(run: (remainingMs: () => number) => Promise<T>, hook: GuardTerminal["hook"], host: "omp" | "claude"): Promise<T> {
  const budget = budgetFor(hook, host);
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(new DOMException("Jev handler timed out.", "TimeoutError")), budget.decisionMs);
  try {
    return await budgets.run({ until: performance.now() + budget.decisionMs, signal: controller.signal, budget }, run, preflightTimeout);
  } finally {
    clearTimeout(timer);
  }
}

/** A budget that reserves a whole try keeps room for one; otherwise the next try shares whatever remains before the host deadline. */
function mayRetry(cause: unknown, backoff: number): boolean {
  const store = budgets.getStore();
  if (store?.signal.aborted) return false;
  if (store && store.until - performance.now() < (store.budget.reserveWholeTry ? store.budget.tryMs : 1) + backoff) return false;
  return RETRYABLE_FAILURES.has(failureType(cause));
}

/**
 * Cuts `text` into at most MAX_CHUNKS pieces whose JSON-escaped size is at most `room` bytes.
 * Each piece starts up to `overlap` escaped bytes before the previous one ended,
 * so every span of up to `overlap` minus one character's escape width lies whole inside some piece. Returns null when no complete cover fits.
 */
export function splitForRoom(text: string, room: number, overlap = CHUNK_OVERLAP_BYTES): string[] | null {
  if (room < 2 * overlap + 64 || text.length > MAX_CHUNKS * room) return null;
  const points = Array.from(text);
  const sizes = points.map((point) => Buffer.byteLength(JSON.stringify(point), "utf8") - 2);
  const pieces: string[] = [];
  let start = 0;
  for (;;) {
    let end = start;
    let used = 0;
    while (end < points.length && used + sizes[end] <= room) used += sizes[end++];
    if (end === points.length) {
      pieces.push(points.slice(start).join(""));
      return pieces;
    }
    pieces.push(points.slice(start, end).join(""));
    if (pieces.length >= MAX_CHUNKS) return null;
    let back = 0;
    start = end;
    while (start > 0 && back + sizes[start - 1] <= overlap) back += sizes[--start];
  }
}

function preflightTimeout(): number {
  const budget = budgets.getStore();
  budget?.signal.throwIfAborted();
  const remaining = budget ? Math.ceil(budget.until - performance.now()) : OMP_RESULT_BUDGET.decisionMs;
  if (remaining <= 0) throw new DOMException("Jev handler timed out.", "TimeoutError");
  return remaining;
}

/** Each installation owns one canonical client; no credential enters its environment or argv. */
export function createGuardService(context: GuardServiceContext): GuardService {
  const active = context.noHelpers !== true && context.project === "firstmate";
  const host = context.host ?? "omp";
  let apiKey: string | undefined;
  const clients = new Map<number, JevClient>();
  const ledger = resolve(context.state, "jev-guard.jsonl");

  function permitted(requestText: string): void {
    const timeout = preflightTimeout();
    try {
      execFileSync("bash", ["-c", '. "$1"; s=$(mktemp) || exit 1; fm_typesafe_permitted "$(cat)" "$2" "$s"; rc=$?; rm -f "$s"; exit "$rc"',
        "jev-guard", lib, resolve(context.config, "dispatch-never-send")], {
        input: requestText, stdio: ["pipe", "ignore", "ignore"], timeout,
      });
    } catch (cause) {
      throw new GuardUnavailableError("PrivacyWithheldError", false, cause);
    }
  }

  function typesafeKey(): string {
    const timeout = preflightTimeout();
    try {
      return execFileSync("bash", ["-c", '. "$1"; fm_typesafe_key "$2" && printf %s "$TYPESAFE_API_KEY_PRIVATE"', "jev-guard", lib, context.home], {
        encoding: "utf8", stdio: ["ignore", "pipe", "ignore"], timeout,
      });
    } catch (cause) {
      throw new GuardUnavailableError("CredentialUnavailableError", false, cause);
    }
  }

  return {
    active,
    host,
    async decide(state, questions) {
      const budget = budgets.getStore()?.budget ?? budgetFor("tool_result", host);
      let requestStarted = false;
      let tries = 0;
      let started = 0;
      try {
        if (!active) throw new GuardUnavailableError("InactiveGuardError");
        const body = { model: GUARD_MODEL, state, questions };
        validateRequest(body);
        const requestText = JSON.stringify(body);
        if (Buffer.byteLength(requestText, "utf8") > MAX_REQUEST_BYTES) throw new GuardUnavailableError("RequestTooLargeError");
        const snapshot: unknown = JSON.parse(requestText);
        validateRequest(snapshot);
        permitted(requestText);
        apiKey ??= typesafeKey();
        let client = clients.get(budget.tryMs);
        if (!client) {
          client = new JevClient({ provider: "typesafe", apiKey, model: GUARD_MODEL, timeoutMs: budget.tryMs,
            baseUrl: process.env.FM_TEST_SEAM === "1" ? process.env.FM_JEV_GUARD_BASE_URL || undefined : undefined });
          clients.set(budget.tryMs, client);
        }
        requestStarted = true;
        started = performance.now();
        for (;;) {
          tries++;
          try {
            return await client.systemOne(snapshot.state, snapshot.questions, { signal: budgets.getStore()?.signal });
          } catch (cause) {
            const backoff = budget.backoffMs * tries;
            if (tries >= budget.tries || !mayRetry(cause, backoff)) throw cause;
            await sleep(backoff, undefined, { signal: budgets.getStore()?.signal });
          }
        }
      } catch (cause) {
        if (cause instanceof GuardUnavailableError) throw cause;
        throw new GuardUnavailableError(failureType(cause), requestStarted, cause,
          requestStarted ? { attempts: tries, elapsedMs: Math.round(performance.now() - started) } : undefined);
      }
    },
    plan(state, field, questions) {
      const text = state[field];
      if (typeof text !== "string") throw new GuardUnavailableError("InvalidToolInputError");
      if (text.length > MAX_CHUNKS * MAX_REQUEST_BYTES) throw new GuardUnavailableError("RequestTooLargeError");
      const whole = JSON.stringify({ model: GUARD_MODEL, state, questions });
      if (Buffer.byteLength(whole, "utf8") <= MAX_REQUEST_BYTES) return [text];
      const frame = Buffer.byteLength(JSON.stringify({ model: GUARD_MODEL, state: { ...state, [field]: "" }, questions }), "utf8");
      const pieces = splitForRoom(text, MAX_REQUEST_BYTES - frame);
      if (!pieces) throw new GuardUnavailableError("RequestTooLargeError");
      // The never-send policy sees the whole payload before any piece leaves, so one clean piece is never sent beside a refused one.
      permitted(whole);
      return pieces;
    },
    record(terminal) {
      const result = terminal.result;
      const answered = terminal.results ?? (result ? [result] : []);
      // Settlement keeps all unanswered pieces, even when a policy block wins over an outage.
      const failures = terminal.failures ?? [];
      const sentFailures = failures.filter((failure) => failure.request_started);
      const chunks = answered.length + sentFailures.length;
      const requestStarted = chunks > 0;
      const plannedChunks = terminal.chunks ?? (requestStarted ? 1 : 0);
      const attempts = [...answered.map((r) => r.meta.attempts), ...sentFailures.flatMap((failure) => failure.attempts ?? [])];
      const times = [...answered.map((r) => r.meta.elapsedMs), ...sentFailures.flatMap((failure) => failure.ms ?? [])];
      const knownCost = answered.length === 1 ? answered[0].meta.cost : totalCost(answered);
      const incomplete = requestStarted && answered.length < plannedChunks;
      const cost = {
        ...(incomplete ? { amount: null, source: "unknown" } : requestStarted ? knownCost : { amount: null, source: "not_called" }),
        incomplete,
        // Keep the known subtotal without presenting it as the charge for the whole payload.
        reported_amount: sum(answered.flatMap((r) => r.meta.cost.source === "reported" && r.meta.cost.amount !== null ? [r.meta.cost.amount] : [])),
      };
      // Question IDs and answer fields are allowlisted; provider extensions can contain input text.
      const answers: Record<string, { type: "noul"; noul: number } | { type: "choice"; choice: string; confidence: number }> = {};
      if (result) {
        for (const key of ["effect", "destructive_intent", "kind", "contains_secret", "injection"]) {
          const answer = result.answers[key];
          if (answer?.type === "noul") answers[key] = { type: "noul", noul: answer.noul };
          else if (answer?.type === "choice") answers[key] = { type: "choice", choice: answer.choice, confidence: answer.confidence };
        }
      }
      const row = {
        kind: "terminal", at: Date.now(), task: context.task, policy_version: GUARD_POLICY_VERSION, outage_policy: OUTAGE_POLICY,
        thresholds: { bash: BASH_THRESHOLDS, write: WRITE_THRESHOLDS, injection: SCREEN_THRESHOLDS },
        hook: terminal.hook, tool: terminal.tool, decision: terminal.decision, enforcement: terminal.enforcement, branch: terminal.branch,
        error_type: terminal.error_type, request_started: requestStarted,
        ...((terminal.tool === "write" || terminal.tool === "edit") && terminal.enforcement === "pretool_deny"
          && terminal.refused_path !== undefined ? { refused_path: terminal.refused_path } : {}),
        provider: result?.meta.provider ?? (requestStarted ? "typesafe" : null),
        requested_model: requestStarted ? GUARD_MODEL : null, model: result?.model ?? null,
        attempts: attempts.length > 0 ? sum(attempts) : null,
        ms: times.length > 0 ? Math.max(...times) : null,
        failures,
        usage: answered.length > 0 ? { input_tokens: sum(answered.map((r) => r.usage.input_tokens)), output_tokens: sum(answered.map((r) => r.usage.output_tokens)) } : null,
        cost,
        chunks, planned_chunks: plannedChunks, answers,
      };
      try {
        appendFileSync(ledger, JSON.stringify(row) + "\n", { mode: 0o600 });
      } catch (cause) {
        throw new GuardUnavailableError("AuditUnavailableError", terminal.request_started, cause);
      }
      // Mirror only the named size refusal, never raw inputs or a second judgment.
      // This optional bridge must not acquire the mandatory Jev audit's semantics.
      if (active && terminal.error_type === "RequestTooLargeError") {
        try {
          execFileSync("python3", [resolve(dirname(fileURLToPath(import.meta.url)), "../../fm-friction-ledger.py"),
            "refusal", "FM-JEV-SIZE", "complete-screening-budget", `${terminal.hook}-${terminal.tool}`,
            `${context.task}:${terminal.hook}:${terminal.tool}`, terminal.tool === "write" || terminal.tool === "edit" ? "machine" : "human-only",
            context.task, fileURLToPath(import.meta.url)], {
            env: { ...process.env, FM_HOME: context.home, FM_FRICTION_ACTOR: "worker" }, stdio: ["ignore", "ignore", "inherit"], timeout: preflightTimeout(),
          });
        } catch {
          console.error("fm-friction: size telemetry unavailable; guarded result unchanged; retry telemetry later with the same event identity");
        }
      }
    },
  };
}
