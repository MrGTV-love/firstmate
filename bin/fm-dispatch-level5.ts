// Firstmate policy around the vendored Level 5 questions and pure decisions.
// CLI: prepare <rules> <task> <project> <allowed-harnesses-json>,
// call (request on stdin, key on fd 3), apply <rules> <response> <prepared>.
import { readFileSync, writeFileSync } from "node:fs";
import { JevClient, ContractError, validateResponse } from "./ten-levels/src/core/client.ts";
import { choice } from "./ten-levels/src/core/helpers.ts";
import { validateRequest } from "./ten-levels/src/core/types.ts";
import { agentQuestions, decideAgent } from "./ten-levels/src/levels/level05/agent-router.ts";
import { modelQuestions, decideModel } from "./ten-levels/src/levels/level05/model-router.ts";
import type { ModelRoute } from "./ten-levels/src/levels/level05/model-router.ts";
import type { AgentRoute } from "./ten-levels/src/levels/level05/agent-router.ts";
import type { SystemOneRequest } from "./ten-levels/src/core/types.ts";

type Profile = Record<string, unknown> & { harness: string; model?: string; effort?: string };
type Rule = Record<string, unknown> & { when: string; use: Profile[] };
type Config = Record<string, unknown> & { rules: Rule[]; default: Profile[] };
type Route = { deterministic?: boolean; agent?: AgentRoute; model?: ModelRoute; effort_score?: number; escalate?: string };
const [action, ...args] = process.argv.slice(2);
const levels = ["low", "medium", "high", "xhigh", "max"];
function object(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}
function profiles(value: unknown): Profile[] {
  const entries: unknown[] = Array.isArray(value) ? value : value === undefined ? [] : [value];
  return entries.map(p => {
    if (!object(p) || typeof p.harness !== "string" ||
      (p.model !== undefined && typeof p.model !== "string") ||
      (p.effort !== undefined && (typeof p.effort !== "string" || (!levels.includes(p.effort) && p.effort !== "ultra")))) throw new Error("profile");
    // Construct the validated consumed fields; retain untouched captain gates.
    return { ...p, harness: p.harness, ...(typeof p.model === "string" ? { model: p.model } : {}),
      ...(typeof p.effort === "string" ? { effort: p.effort } : {}) };
  });
}
function config(path: string): Config {
  const value: unknown = JSON.parse(readFileSync(path, "utf8"));
  if (!object(value) || !Array.isArray(value.rules)) throw new Error("rules");
  return { ...value, rules: value.rules.map((r: unknown) => {
    if (!object(r) || typeof r.when !== "string") throw new Error("rule");
    return { ...r, when: r.when, use: profiles(r.use) };
  }), default: profiles(value.default) };
}
function prepare(cfg: Config, task: string, project: string, allowed: string[]) {
  const intent = task.match(/## Captain's intent\n([\s\S]*?)(?=\n## |$)/)?.[1] ?? task;
  const claudeRequired = /^(?:please\s+)?(?:use|run|launch|require|must use|only use)\s+(?:the\s+)?Claude(?: Code)?\b/im.test(intent)
    || /^(?:please\s+)?(?:fix|repair|implement|add|change|update|test|debug|validate|investigate|diagnose|audit)\b[^\n]*\bClaude(?: Code)?(?:[- ](?:only|specific)|\s+(?:PreToolUse|PostToolUse|hook|hooks))\b/im.test(intent);
  const criteria: Record<string, string> = {};
  let direct: string | undefined;
  for (const [i, rule] of cfg.rules.entries()) {
    const id = `rule_${i + 1}`;
    // Exact captain policy boundaries; task difficulty remains a Jev judgment.
    if (/^Ship task in the Vernant project\b/.test(rule.when) && project !== "vernant") continue;
    if (/^Non-Vernant\b/.test(rule.when) && project === "vernant") continue;
    const claudeOnly = /^Only when the captain expressly requires Claude\b/.test(rule.when);
    if (claudeOnly && !claudeRequired) continue;
    if (claudeOnly && claudeRequired) direct = id;
    if (!direct && !rule.use.some(p => allowed.includes(p.harness))) continue;
    criteria[id] = rule.when;
  }
  criteria.default = "No listed rule applies to this task.";
  if (Object.keys(criteria).length === 1) direct = "default";
  const request: SystemOneRequest = { model: "jev-latest", state: { task, repository: project }, questions: {
    rule: choice("Which ONE dispatch rule best fits `task` in `repository`? Pick default when no listed condition is met, including exemptions.", criteria),
    ...agentQuestions, ...modelQuestions,
  }};
  return { request, direct, allowed };
}
try {
  if (action === "prepare") {
    const [rulesPath, taskPath, project, allowedJson] = args;
    const allowed: unknown = JSON.parse(allowedJson);
    if (!Array.isArray(allowed) || !allowed.every((h: unknown) => typeof h === "string")) throw new Error("allowed");
    console.log(JSON.stringify(prepare(config(rulesPath), readFileSync(taskPath, "utf8"), project, allowed)));
  } else if (action === "call") {
    const request: unknown = JSON.parse(readFileSync(0, "utf8"));
    validateRequest(request);
    const apiKey = readFileSync(3, "utf8").trim();
    const client = new JevClient({ provider: "typesafe", apiKey, timeoutMs: 5000,
      pricing: { inputPerMillion: 0.042, outputPerMillion: 0 },
      ...(process.env.FM_TEST_SEAM === "1" && process.env.FM_TYPESAFE_TEST_ENDPOINT
        ? { baseUrl: process.env.FM_TYPESAFE_TEST_ENDPOINT } : {}) });
    console.log(JSON.stringify(await client.systemOne(request.state, request.questions, { model: request.model })));
  } else if (action === "apply") {
    const [rulesPath, responsePath, preparedPath] = args;
    const cfg = config(rulesPath);
    const prepared: unknown = JSON.parse(readFileSync(preparedPath, "utf8"));
    if (!object(prepared) || !Array.isArray(prepared.allowed) || !prepared.allowed.every((h: unknown) => typeof h === "string") ||
      (prepared.direct !== undefined && typeof prepared.direct !== "string")) throw new Error("prepared");
    validateRequest(prepared.request);
    const allowed: string[] = prepared.allowed;
    let response: Record<string, unknown>;
    let route: Route;
    if (prepared.direct) {
      const q = prepared.request.questions.rule;
      if (q.type !== "choice" || !Object.hasOwn(q.criteria, prepared.direct)) throw new Error("direct");
      const probabilities = Object.fromEntries(Object.keys(q.criteria).map(k => [k, k === prepared.direct ? 1 : 0]));
      response = { answers: { rule: { type: "choice", choice: prepared.direct, confidence: 1, probabilities } } };
      route = { deterministic: true };
    } else {
      const value: unknown = JSON.parse(readFileSync(responsePath, "utf8"));
      validateResponse(value, prepared.request.questions);
      response = value;
      const a = value.answers;
      if (a.profile.type !== "choice" || a.ambiguity.type !== "score" || a.needs_desktop.type !== "noul" ||
        a.model.type !== "choice" || a.effort.type !== "score") throw new Error("answer");
      const agent = decideAgent(a.profile, a.ambiguity, a.needs_desktop);
      const model = decideModel(a.model, a.effort);
      route = { agent, model, effort_score: a.effort.score };
      if (agent.profile === "human" || a.ambiguity.score > 1 || agent.needsDesktopAccess || agent.profile === "browser_agent" || agent.profile === "deterministic_script") {
        route.escalate = a.ambiguity.score > 1 ? "high task ambiguity requires firstmate judgment" : `${agent.profile} requires an explicit handler or capability decision`;
      }
    }
    const requested = route.model?.effort ?? "low";
    const mapProfiles = (use: Profile[]) => {
      let ps = use.filter(p => allowed.includes(p.harness));
      if (!prepared.direct) {
        const inexpensive = ps.filter(p => /(?:haiku|luna)/i.test(p.model ?? ""));
        if (route.model?.model === "fast" && inexpensive.length) ps = inexpensive;
        if (route.model?.model === "powerful") ps = ps.filter(p => !/(?:haiku|luna)/i.test(p.model ?? ""));
      }
      return ps.map(p => {
        if (!p.effort || p.effort === "ultra") return p;
        const effort = /haiku/i.test(p.model ?? "") ? "max" : levels[Math.max(levels.indexOf(p.effort), levels.indexOf(requested))];
        return { ...p, effort };
      });
    };
    cfg.rules = cfg.rules.map(r => ({ ...r, use: mapProfiles(r.use) }));
    cfg.default = mapProfiles(cfg.default);
    writeFileSync(rulesPath, JSON.stringify(cfg));
    console.log(JSON.stringify({ ...response, route }));
  } else throw new Error("unknown action");
} catch (error) {
  // Never echo arbitrary API bodies, request text, credentials, or fetch URLs.
  const http = error instanceof Error ? error.message.match(/^typesafe HTTP ([0-9]{3})\./)?.[1] : undefined;
  const category = http ? `TypeSafe HTTP ${http}` : error instanceof ContractError ? "invalid provider answer contract"
    : error instanceof Error && error.name === "TimeoutError" ? "request deadline exceeded" : "request or local policy failure";
  console.error(`dispatch-level5: ${category}`);
  process.exitCode = 1;
}
