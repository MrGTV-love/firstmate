/** Firstmate's bounded Jev service and minimized audit owner; see docs/configuration.md. */
import { AsyncLocalStorage } from "node:async_hooks";
import { Buffer } from "node:buffer";
import { randomUUID } from "node:crypto";
import { execFileSync, spawn } from "node:child_process";
import { appendFileSync, readFileSync, renameSync, writeFileSync } from "node:fs";
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
/** Outage-only deny guidance; the worker adapter owns policy-refusal next steps. */
export const OUTAGE_NOTICE = "The review could not run, so this is not a verdict on the call. You may run the same call once more. "
  + "If it fails the same way, stop and tell the user; do not work around it with another command, tool, path or encoding.";
/** A cooldown refusal names the wait, so the retry it invites cannot meet the cooldown again. */
export function cooldownNotice(seconds: number, ran: boolean): string {
  const again = ran ? "repeat the read once more (a command only if repeating it is safe)" : "run the same call once more";
  return `The review could not run because the judge is cooling down after a recent outage, so this is not a verdict on the ${ran ? "output" : "call"}. `
    + `Wait ${seconds} seconds, then ${again}. `
    + "If it is refused the same way after the wait, stop and tell the user; do not work around it with another command, tool, path or encoding.";
}

interface Budget { tryMs: number; tries: number; decisionMs: number; backoffMs: number; reserveWholeTry: boolean }
// The per-try limit guards only against a judge that never answers; answered calls are far faster
// (p99 535 ms over 15,640 calls, docs/configuration.md "Unreachable threshold").
const WIDE_BUDGET: Budget = { tryMs: 90_000, tries: 3, decisionMs: 300_000, backoffMs: 1_000, reserveWholeTry: true };
// omp 18.12.0 forwards the original output when its nonconfigurable 30-second tool_result deadline passes.
// Its tool_call deadline (extensionHandlers.toolCallTimeoutMs) is raised past WIDE_BUDGET by .omp/fm-worker-overlay.yml.
const OMP_RESULT_BUDGET: Budget = { tryMs: 12_000, tries: 2, decisionMs: 25_000, backoffMs: 500, reserveWholeTry: false };
const budgetFor = (hook: GuardTerminal["hook"], host: "omp" | "claude"): Budget => host === "omp" && hook === "tool_result" ? OMP_RESULT_BUDGET : WIDE_BUDGET;
const COOLDOWN_MS = 60_000;
const RETRYABLE_FAILURES: ReadonlySet<GuardFailureType> = new Set(["TimeoutError", "TypeError", "Error"]);
const lib = resolve(dirname(fileURLToPath(import.meta.url)), "../../fm-typesafe-lib.sh");
const budgets = new AsyncLocalStorage<{ until: number; signal: AbortSignal; budget: Budget }>();

export type GuardFailureType = "ContractError" | "QuestionValidationError" | "TimeoutError" | "AbortError"
  | "TypeError" | "Error" | "PrivacyWithheldError" | "CredentialUnavailableError" | "RequestTooLargeError"
  | "AuditUnavailableError" | "InvalidToolInputError" | "UnsupportedToolResultError"
  | "InactiveGuardError" | "CooldownActiveError";

export class GuardUnavailableError extends Error {
  readonly errorType: GuardFailureType;
  readonly requestStarted: boolean;
  /** Provider tries and elapsed time; null when no request started. */
  readonly attempts: number | null;
  readonly elapsedMs: number | null;
  /** True when the whole decision budget ran out; a request that started then counts as an exhausted decision. */
  readonly exhausted: boolean;
  /** Whole seconds left on the judge cooldown; set only on the cooldown refusal. */
  readonly cooldownSeconds: number | null;
  constructor(errorType: GuardFailureType, requestStarted = false, cause?: unknown, timing?: { attempts: number; elapsedMs: number; exhausted: boolean },
    cooldownSeconds?: number) {
    super("Jev guard requires review.", { cause });
    this.name = errorType;
    this.errorType = errorType;
    this.requestStarted = requestStarted;
    this.attempts = timing?.attempts ?? null;
    this.elapsedMs = timing?.elapsedMs ?? null;
    this.exhausted = timing?.exhausted ?? false;
    this.cooldownSeconds = cooldownSeconds ?? null;
  }
}

/** Failure rows carry the guard's own try count and elapsed time, so a timeout can be told from an error. */
export function failureTiming(error: unknown): { attempts: number | null; ms: number | null; exhausted: boolean; cooldown_s: number | null } {
  return error instanceof GuardUnavailableError
    ? { attempts: error.attempts, ms: error.elapsedMs, exhausted: error.exhausted, cooldown_s: error.cooldownSeconds }
    : { attempts: null, ms: null, exhausted: false, cooldown_s: null };
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
  /** Set on failure rows, where no result carries meta. */
  attempts?: number | null;
  ms?: number | null;
  /** The whole decision budget ran out; with a started request it starts the judge cooldown. Never logged. */
  exhausted?: boolean;
  /** Seconds left on the judge cooldown when it refused the call; the worker notice only, never logged. */
  cooldown_s?: number | null;
  result?: SystemOneResult;
  /** Set only when an oversized payload was screened in pieces: the piece count and every answered piece. */
  chunks?: number;
  results?: SystemOneResult[];
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
  const breaker = resolve(context.state, ".jev-guard-breaker");

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
        let until = 0;
        try { until = Number(readFileSync(breaker, "utf8")); } catch { /* No observed outage means no cooldown. */ }
        if (Number.isFinite(until) && until > Date.now()) {
          throw new GuardUnavailableError("CooldownActiveError", false, undefined, undefined, Math.ceil((until - Date.now()) / 1000));
        }
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
          requestStarted ? { attempts: tries, elapsedMs: Math.round(performance.now() - started), exhausted: budgets.getStore()?.signal.aborted === true } : undefined);
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
      // Every answered piece counts toward the totals; a failed piece adds its own tries and time.
      const answered = terminal.results ?? (result ? [result] : []);
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
        error_type: terminal.error_type, request_started: terminal.request_started,
        ...((terminal.tool === "write" || terminal.tool === "edit") && terminal.enforcement === "pretool_deny"
          && terminal.refused_path !== undefined ? { refused_path: terminal.refused_path } : {}),
        provider: result?.meta.provider ?? (terminal.request_started ? "typesafe" : null),
        requested_model: terminal.request_started ? GUARD_MODEL : null, model: result?.model ?? null,
        attempts: answered.length > 0 || terminal.attempts != null ? sum(answered.map((r) => r.meta.attempts)) + (terminal.attempts ?? 0) : null,
        ms: answered.length > 0 || terminal.ms != null ? Math.max(terminal.ms ?? 0, ...answered.map((r) => r.meta.elapsedMs)) : null,
        usage: answered.length > 0 ? { input_tokens: sum(answered.map((r) => r.usage.input_tokens)), output_tokens: sum(answered.map((r) => r.usage.output_tokens)) } : null,
        cost: answered.length > 1 ? totalCost(answered) : result?.meta.cost ?? { amount: null, source: terminal.request_started ? "unknown" : "not_called" },
        chunks: terminal.chunks ?? (terminal.request_started ? 1 : 0), answers,
      };
      try {
        appendFileSync(ledger, JSON.stringify(row) + "\n", { mode: 0o600 });
        if ((terminal.error_type === "TimeoutError" || terminal.error_type === "TypeError" || terminal.error_type === "Error")
          && terminal.request_started && (terminal.exhausted === true || (terminal.ms ?? 0) >= budgetFor(terminal.hook, host).tryMs)) {
          const temporary = `${breaker}.${process.pid}.${randomUUID()}`;
          writeFileSync(temporary, String(Date.now() + COOLDOWN_MS), { mode: 0o600 });
          renameSync(temporary, breaker);
          // The existing health owner serializes and deduplicates alerts. Never spend the remaining host budget waiting on it.
          const health = spawn(resolve(dirname(lib), "fm-typesafe-health.sh"), ["record", "000", "jev-guard"], {
            env: { ...process.env, FM_HOME: context.home, FM_STATE_OVERRIDE: context.state, FM_CONFIG_OVERRIDE: context.config },
            stdio: "ignore",
          });
          health.on("error", () => {});
          health.unref();
        }
      } catch (cause) {
        throw new GuardUnavailableError("AuditUnavailableError", terminal.request_started, cause);
      }
    },
  };
}
