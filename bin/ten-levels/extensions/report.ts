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
const lib = resolve(dirname(fileURLToPath(import.meta.url)), "../../fm-typesafe-lib.sh");
const budgets = new AsyncLocalStorage<{ until: number; signal: AbortSignal }>();

export type GuardFailureType = "ContractError" | "QuestionValidationError" | "TimeoutError" | "AbortError"
  | "TypeError" | "Error" | "PrivacyWithheldError" | "CredentialUnavailableError" | "RequestTooLargeError"
  | "AuditUnavailableError" | "InvalidToolInputError" | "UnsupportedToolResultError"
  | "InactiveGuardError";

export class GuardUnavailableError extends Error {
  readonly errorType: GuardFailureType;
  readonly requestStarted: boolean;
  constructor(errorType: GuardFailureType, requestStarted = false, cause?: unknown) {
    super("Jev guard requires review.", { cause });
    this.name = errorType;
    this.errorType = errorType;
    this.requestStarted = requestStarted;
  }
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
  result?: SystemOneResult;
}

export interface GuardService {
  readonly active: boolean;
  readonly host: "omp" | "claude";
  decide(state: State, questions: Questions): Promise<SystemOneResult>;
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
      try {
        if (!active) throw new GuardUnavailableError("InactiveGuardError");
        const body = { model: GUARD_MODEL, state, questions };
        validateRequest(body);
        const requestText = JSON.stringify(body);
        if (Buffer.byteLength(requestText, "utf8") > MAX_REQUEST_BYTES) throw new GuardUnavailableError("RequestTooLargeError");
        const snapshot: unknown = JSON.parse(requestText);
        validateRequest(snapshot);
        permitted(requestText);
        client ??= new JevClient({ provider: "typesafe", apiKey: typesafeKey(), model: GUARD_MODEL, timeoutMs: 10_000,
          baseUrl: process.env.FM_TEST_SEAM === "1" ? process.env.FM_JEV_GUARD_BASE_URL || undefined : undefined });
        requestStarted = true;
        return await client.systemOne(snapshot.state, snapshot.questions, { signal: budgets.getStore()?.signal });
      } catch (cause) {
        if (cause instanceof GuardUnavailableError) throw cause;
        throw new GuardUnavailableError(failureType(cause), requestStarted, cause);
      }
    },
    record(terminal) {
      const result = terminal.result;
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
        attempts: result?.meta.attempts ?? null, ms: result?.meta.elapsedMs ?? null,
        usage: result ? { input_tokens: result.usage.input_tokens, output_tokens: result.usage.output_tokens } : null,
        cost: result?.meta.cost ?? { amount: null, source: terminal.request_started ? "unknown" : "not_called" }, answers,
      };
      try {
        appendFileSync(ledger, JSON.stringify(row) + "\n", { mode: 0o600 });
      } catch (cause) {
        throw new GuardUnavailableError("AuditUnavailableError", terminal.request_started, cause);
      }
    },
  };
}
