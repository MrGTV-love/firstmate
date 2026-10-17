/** Firstmate's bounded Jev service and minimized audit owner; see docs/configuration.md. */
import { AsyncLocalStorage } from "node:async_hooks";
import { Buffer } from "node:buffer";
import { execFileSync } from "node:child_process";
import { appendFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
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
/** Outage-only deny text; policy blocks keep the permanent BLOCK_NOTICE. */
export const OUTAGE_NOTICE = "The review could not run, so this is not a verdict on the call. You may run the same call once more. "
  + "If it fails the same way, stop and tell the user; do not work around it with another command, tool, path or encoding.";
const TRY_MS = 10_000;
const MAX_TRIES = 2;
const RETRYABLE_FAILURES: ReadonlySet<GuardFailureType> = new Set(["TimeoutError", "TypeError", "Error"]);
const lib = resolve(dirname(fileURLToPath(import.meta.url)), "../../fm-typesafe-lib.sh");
const budgets = new AsyncLocalStorage<{ until: number; signal: AbortSignal }>();

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
  branch: "policy" | "deterministic" | "device" | "empty" | "outage" | "inactive" | "supervisor_consistency";
  error_type: GuardFailureType | null;
  request_started: boolean;
  /** Set on failure rows, where no result carries meta. */
  attempts?: number | null;
  ms?: number | null;
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

export async function withDecisionBudget<T>(run: () => Promise<T>): Promise<T> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(new DOMException("Jev handler timed out.", "TimeoutError")), 25_000);
  try {
    return await budgets.run({ until: performance.now() + 25_000, signal: controller.signal }, run);
  } finally {
    clearTimeout(timer);
  }
}

/** One retry for an outage of a required judgment, only when a whole further try fits the handler budget. */
function mayRetry(cause: unknown): boolean {
  const budget = budgets.getStore();
  if (budget?.signal.aborted) return false;
  if (budget && budget.until - performance.now() < TRY_MS) return false;
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
  const remaining = budget ? Math.ceil(budget.until - performance.now()) : 25_000;
  if (remaining <= 0) throw new DOMException("Jev handler timed out.", "TimeoutError");
  return remaining;
}

/** Each installation owns one canonical client; no credential enters its environment or argv. */
export function createGuardService(context: GuardServiceContext): GuardService {
  const active = context.noHelpers !== true && context.project === "firstmate";
  let client: JevClient | undefined;
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
    host: context.host ?? "omp",
    async decide(state, questions) {
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
        client ??= new JevClient({ provider: "typesafe", apiKey: typesafeKey(), model: GUARD_MODEL, timeoutMs: TRY_MS,
          baseUrl: process.env.FM_TEST_SEAM === "1" ? process.env.FM_JEV_GUARD_BASE_URL || undefined : undefined });
        requestStarted = true;
        started = performance.now();
        for (;;) {
          tries++;
          try {
            return await client.systemOne(snapshot.state, snapshot.questions, { signal: budgets.getStore()?.signal });
          } catch (cause) {
            if (tries >= MAX_TRIES || !mayRetry(cause)) throw cause;
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
      } catch (cause) {
        throw new GuardUnavailableError("AuditUnavailableError", terminal.request_started, cause);
      }
    },
  };
}
