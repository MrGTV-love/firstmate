/**
 * The side channel every agent level extension reports on.
 *
 * Firstmate copy of upstream apps/ten-levels/extensions/report.ts; ../SOURCE.md lists every change.
 * One JSON line per event goes to the owning home's private state/jev-guard.jsonl instead of the
 * lab's stderr stream. The same payload is appended to the pi session as a custom entry, so the
 * session file holds the permanent record.
 *
 * `decide` is the one way an extension calls Jev: it validates, calls, reports, and returns.
 * `extra` must not use the keys the report already sets: source, state, questions, answers, usage, model, ms.
 */
import { AsyncLocalStorage } from "node:async_hooks";
import { execFileSync } from "node:child_process";
import { appendFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { JevClient } from "../src/core/client.ts";
import { validateQuestions, type Answer, type Questions, type State } from "../src/core/types.ts";

const bin = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const lib = resolve(bin, "fm-typesafe-lib.sh");
let home = resolve(bin, "..");
let config = resolve(home, "config");
let ledger: string | undefined;
let task = "";

const budgets = new AsyncLocalStorage<{ until: number; signal: AbortSignal }>();

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

/** Firstmate: the owning home, its config and state directories, and the task this session runs. */
export function configure(c: { home: string; config: string; state: string; task: string }): void {
  home = c.home;
  config = c.config;
  ledger = resolve(c.state, "jev-guard.jsonl");
  task = c.task;
}

/** Firstmate: the single primary-home key, resolved at call time and never placed in the environment. */
function typesafeKey(): string {
  return execFileSync("bash", ["-c", '. "$1"; fm_typesafe_key "$2" && printf %s "$TYPESAFE_API_KEY_PRIVATE"', "jev-guard", lib, home], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "ignore"],
    timeout: preflightTimeout(),
  });
}

/** Firstmate: the OpenRouter fallback key from the same home .env, used only after TypeSafe direct fails. */
function openrouterKey(): string {
  return execFileSync("bash", ["-c", '. "$1"; fm_openrouter_key "$2" && printf %s "$OPENROUTER_API_KEY_PRIVATE"', "jev-guard", lib, home], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "ignore"],
    timeout: preflightTimeout(),
  });
}

/** Firstmate: the existing config/dispatch-never-send policy decides what may leave the machine. */
function permitted(state: State): void {
  execFileSync("bash", ["-c", '. "$1"; s=$(mktemp) || exit 1; fm_typesafe_permitted "$(cat)" "$2" "$s"; rc=$?; rm -f "$s"; exit "$rc"', "jev-guard", lib, resolve(config, "dispatch-never-send")], {
    input: JSON.stringify(state),
    stdio: ["pipe", "ignore", "ignore"],
    timeout: preflightTimeout(),
  });
}

const seam = (name: string) => process.env.FM_TEST_SEAM === "1" ? process.env[name] || undefined : undefined;
let client: JevClient | undefined;
export const jev = () => (client ??= new JevClient({ provider: "typesafe", apiKey: typesafeKey(), baseUrl: seam("FM_JEV_GUARD_BASE_URL"), timeoutMs: 10_000 }));
let fallback: JevClient | undefined;
const openrouter = () => (fallback ??= new JevClient({ provider: "openrouter", apiKey: openrouterKey(), baseUrl: seam("FM_JEV_GUARD_OPENROUTER_URL"), timeoutMs: 10_000 }));

/** Firstmate: TypeSafe direct first; OpenRouter only when the direct call is unavailable or fails. */
async function systemOne(state: State, questions: Questions) {
  try {
    return await jev().systemOne(state, questions, { signal: budgets.getStore()?.signal });
  } catch (direct) {
    try {
      preflightTimeout();
      return await openrouter().systemOne(state, questions, { signal: budgets.getStore()?.signal });
    } catch {
      throw direct;
    }
  }
}

/** The level config the lab passed in, JEV_LEVEL_CONFIG as JSON. */
export function levelConfig<T extends object>(fallback: T): T {
  try {
    const raw = process.env.JEV_LEVEL_CONFIG;
    return raw ? { ...fallback, ...(JSON.parse(raw) as Partial<T>) } : fallback;
  } catch {
    return fallback;
  }
}

export function report(pi: any, kind: string, payload: Record<string, unknown>): void {
  const { source, hook, tool, block, flag, noul, answers, model, provider, ms } = payload;
  const usage = payload.usage as Decision["usage"] | undefined;
  const body = { kind, at: Date.now(), task, source, hook, tool, block, flag, noul, answers, model, provider, ms,
    usage: usage && { input_tokens: usage.input_tokens, output_tokens: usage.output_tokens, cost: usage.cost } };
  try { if (ledger) appendFileSync(ledger, JSON.stringify(body) + "\n", { mode: 0o600 }); } catch { /* the ledger is optional */ }
  try { pi.appendEntry?.(`jev-${kind}`, payload); } catch { /* entries are optional */ }
}

export interface Decision {
  answers: Record<string, Answer>;
  usage: { input_tokens: number; output_tokens: number; cost?: number };
  model: string;
  ms: number;
}

/**
 * One Jev call from inside the harness. `source` names who asked, a hook or a tool, so the
 * window can label the row. The full state, questions, and answers travel on the side channel.
 */
export async function decide(pi: any, source: string, state: State, questions: Questions, extra: Record<string, unknown> = {}): Promise<Decision> {
  validateQuestions(questions);
  permitted(state);
  const started = performance.now();
  const result = await systemOne(state, questions);
  const out: Decision = { answers: result.answers, usage: result.usage, model: result.model, ms: Math.round(performance.now() - started) };
  report(pi, "jev", { source, state, questions, answers: out.answers, usage: out.usage, model: out.model, ms: out.ms, provider: result.meta.provider, ...extra });
  return out;
}
