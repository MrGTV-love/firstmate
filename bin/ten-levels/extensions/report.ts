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
import { WRITE_THRESHOLDS } from "../src/levels/level06/index.ts";

export const GUARD_POLICY_VERSION = "FIRSTMATE_JEV_GUARD_V1";
export const OUTAGE_POLICY = "REVIEW_ON_UNAVAILABLE_V1";
export const GUARD_MODEL = "jev-1.13.0";
export const MAX_REQUEST_BYTES = 16_384;
/** A payload over the ceiling is screened as overlapping pieces, each one a complete request that fits it. */
export const MAX_CHUNKS = 16;
/** A span up to 1,000 JSON-escaped bytes always lies whole inside one piece; a longer one can be cut, and each half is still screened. */
export const CHUNK_OVERLAP_BYTES = 1_024;
/** Presentation only: these are the existing screening limits, not a new admission rule. */
const SIZE_REFUSAL_HEAD = `REFUSED: guard=FM-JEV-SIZE rule=complete-screening-budget missing=complete payload coverage within ${MAX_CHUNKS} requests of ${MAX_REQUEST_BYTES} UTF-8 bytes each, including model, questions and JSON framing, with ${CHUNK_OVERLAP_BYTES} JSON-escaped bytes of overlap. `
  + `The ${MAX_CHUNKS * MAX_REQUEST_BYTES}-character coarse precheck is not a usable content budget: UTF-8, escaping, framing and overlap also consume room. `;
export const SIZE_REFUSAL_NOTICE = SIZE_REFUSAL_HEAD
  + "For an unsplittable operation, human-only-exit: what authorized smaller operation preserves the intended effect within this budget?";
/** Outage-only deny guidance; the worker adapter owns policy-refusal next steps. */
export const OUTAGE_NOTICE = "The review could not run, so this is not a verdict on the call. You may run the same call once more. "
  + "If it fails the same way, stop and tell the user; do not work around it with another command, tool, path or encoding.";

// The per-try limit guards only against a judge that never answers; answered calls are far faster
// (p99 535 ms over 15,640 calls, docs/configuration.md "Unreachable threshold").
const TRY_MS = 90_000;
const TRIES = 3;
const DECISION_MS = 300_000;
const BACKOFF_MS = 1_000;
const RETRYABLE_FAILURES: ReadonlySet<GuardFailureType> = new Set(["TimeoutError", "TypeError", "Error"]);
const lib = resolve(dirname(fileURLToPath(import.meta.url)), "../../fm-typesafe-lib.sh");
const budgets = new AsyncLocalStorage<{ until: number; signal: AbortSignal }>();

export type GuardFailureType = "ContractError" | "QuestionValidationError" | "TimeoutError" | "AbortError"
  | "TypeError" | "Error" | "PrivacyWithheldError" | "CredentialUnavailableError" | "RequestTooLargeError"
  | "AuditUnavailableError" | "InvalidToolInputError"
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
}

export interface GuardTerminal {
  hook: "tool_call";
  tool: string;
  decision: "allow" | "block" | "review" | "inactive";
  enforcement: "pretool_allow" | "pretool_deny" | "inactive_no_protection";
  branch: "policy" | "deterministic" | "device" | "outage" | "inactive" | "egress" | "coverage" | "confinement";
  /** Policy owner only; not proof that launch-time OS confinement is active. */
  confinement_owner?: "T5";
  /** The tool's fixed egress class only; no outbound text or addresses. */
  destination_class?: string;
  /** Only refused write/edit paths; never command text or content. */
  refused_path?: string;
  /** Unique UTF-8 content bytes, excluding repeated overlap and request framing. */
  write_coverage?: { model_screened_bytes: number; local_only_bytes: number };
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
  decide(state: State, questions: Questions): Promise<SystemOneResult>;
  /**
   * The pieces of a write that fit within MAX_CHUNKS requests; the caller screens any remainder locally.
   * Each piece gets its own never-send check, so a value longer than the overlap can be cut across a boundary.
   */
  planWrite(state: { path: string; content: string }, questions: Questions): { pieces: string[]; model_screened_bytes: number; local_only_bytes: number };
  record(terminal: GuardTerminal): void;
}

export async function withDecisionBudget<T>(run: () => Promise<T>): Promise<T> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(new DOMException("Jev handler timed out.", "TimeoutError")), DECISION_MS);
  try {
    return await budgets.run({ until: performance.now() + DECISION_MS, signal: controller.signal }, run);
  } finally {
    clearTimeout(timer);
  }
}

/** A retry starts only while the decision budget still has room for one whole try after its backoff. */
function mayRetry(cause: unknown, backoff: number): boolean {
  const store = budgets.getStore();
  if (store?.signal.aborted) return false;
  if (store && store.until - performance.now() < TRY_MS + backoff) return false;
  return RETRYABLE_FAILURES.has(failureType(cause));
}

/** JSON string width without allocating a string or serializing each code point. */
function escapedPointBytes(point: number): number {
  if (point === 0x22 || point === 0x5c || point === 8 || point === 9 || point === 10 || point === 12 || point === 13) return 2;
  if (point < 0x20 || (point >= 0xd800 && point <= 0xdfff)) return 6;
  return point <= 0x7f ? 1 : point <= 0x7ff ? 2 : point <= 0xffff ? 3 : 4;
}

/** Bounded write-only prefix. */
function writePieces(text: string, room: number): { pieces: string[]; covered: number } {
  if (room < 2 * CHUNK_OVERLAP_BYTES + 64) throw new GuardUnavailableError("RequestTooLargeError");
  const pieces: string[] = [];
  let start = 0;
  for (;;) {
    let end = start;
    let used = 0;
    while (end < text.length) {
      const point = text.codePointAt(end)!;
      const bytes = escapedPointBytes(point);
      if (used + bytes > room) break;
      used += bytes;
      end += point > 0xffff ? 2 : 1;
    }
    pieces.push(text.slice(start, end));
    if (end === text.length || pieces.length === MAX_CHUNKS) return { pieces, covered: end };
    let back = 0;
    start = end;
    while (start > 0) {
      const last = text.charCodeAt(start - 1);
      const width = last >= 0xdc00 && last <= 0xdfff && start > 1
        && text.charCodeAt(start - 2) >= 0xd800 && text.charCodeAt(start - 2) <= 0xdbff ? 2 : 1;
      const bytes = escapedPointBytes(text.codePointAt(start - width)!);
      if (back + bytes > CHUNK_OVERLAP_BYTES) break;
      back += bytes;
      start -= width;
    }
  }
}

function preflightTimeout(): number {
  const budget = budgets.getStore();
  budget?.signal.throwIfAborted();
  const remaining = budget ? Math.ceil(budget.until - performance.now()) : DECISION_MS;
  if (remaining <= 0) throw new DOMException("Jev handler timed out.", "TimeoutError");
  return remaining;
}

/** Each installation owns one canonical client; no credential enters its environment or argv. */
export function createGuardService(context: GuardServiceContext): GuardService {
  const active = context.noHelpers !== true && context.project === "firstmate";
  let apiKey: string | undefined;
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
        apiKey ??= typesafeKey();
        const judge = client ??= new JevClient({ provider: "typesafe", apiKey, model: GUARD_MODEL, timeoutMs: TRY_MS,
          baseUrl: process.env.FM_TEST_SEAM === "1" ? process.env.FM_JEV_GUARD_BASE_URL || undefined : undefined });
        requestStarted = true;
        started = performance.now();
        for (;;) {
          tries++;
          try {
            return await judge.systemOne(snapshot.state, snapshot.questions, { signal: budgets.getStore()?.signal });
          } catch (cause) {
            const backoff = BACKOFF_MS * tries;
            if (tries >= TRIES || !mayRetry(cause, backoff)) throw cause;
            await sleep(backoff, undefined, { signal: budgets.getStore()?.signal });
          }
        }
      } catch (cause) {
        if (cause instanceof GuardUnavailableError) throw cause;
        throw new GuardUnavailableError(failureType(cause), requestStarted, cause,
          requestStarted ? { attempts: tries, elapsedMs: Math.round(performance.now() - started) } : undefined);
      }
    },
    planWrite(state, questions) {
      const whole = JSON.stringify({ model: GUARD_MODEL, state, questions });
      const bytes = Buffer.byteLength(state.content, "utf8");
      if (Buffer.byteLength(whole, "utf8") <= MAX_REQUEST_BYTES) {
        return { pieces: [state.content], model_screened_bytes: bytes, local_only_bytes: 0 };
      }
      const frame = Buffer.byteLength(JSON.stringify({ model: GUARD_MODEL, state: { ...state, content: "" }, questions }), "utf8");
      const { pieces, covered } = writePieces(state.content, MAX_REQUEST_BYTES - frame);
      for (const piece of pieces) permitted(JSON.stringify({ model: GUARD_MODEL, state: { ...state, content: piece }, questions }));
      const screened = Buffer.byteLength(state.content.slice(0, covered), "utf8");
      return { pieces, model_screened_bytes: screened, local_only_bytes: bytes - screened };
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
        for (const key of ["kind", "contains_secret"]) {
          const answer = result.answers[key];
          if (answer?.type === "noul") answers[key] = { type: "noul", noul: answer.noul };
          else if (answer?.type === "choice") answers[key] = { type: "choice", choice: answer.choice, confidence: answer.confidence };
        }
      }
      const row = {
        kind: "terminal", at: Date.now(), task: context.task, policy_version: GUARD_POLICY_VERSION, outage_policy: OUTAGE_POLICY,
        thresholds: { write: WRITE_THRESHOLDS },
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
        ...(terminal.destination_class ? { destination_class: terminal.destination_class } : {}),
        ...(terminal.confinement_owner ? { confinement_owner: terminal.confinement_owner } : {}),
        ...(terminal.write_coverage ? { write_coverage: terminal.write_coverage,
          ...(terminal.write_coverage.local_only_bytes > 0 ? { note: "unscreened remainder: deterministic local rules only" } : {}) } : {}),
      };
      try {
        appendFileSync(ledger, JSON.stringify(row) + "\n", { mode: 0o600 });
      } catch (cause) {
        throw new GuardUnavailableError("AuditUnavailableError", terminal.request_started, cause);
      }
      // Mirror only a named size refusal the guard actually enforced, never raw inputs or a second judgment.
      // This optional bridge must not acquire the mandatory Jev audit's semantics.
      if (active && terminal.error_type === "RequestTooLargeError"
        && terminal.enforcement === "pretool_deny") {
        try {
          execFileSync("python3", [resolve(dirname(fileURLToPath(import.meta.url)), "../../fm-friction-ledger.py"),
            "refusal", "FM-JEV-SIZE", "complete-screening-budget", `${terminal.hook}-${terminal.tool}`,
            `${context.task}:${terminal.hook}:${terminal.tool}`, "machine",
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
