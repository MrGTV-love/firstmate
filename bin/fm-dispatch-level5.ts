// Firstmate policy around the vendored Level 5 questions and pure decisions.
// CLI: prepare <rules> <task> <project>, call (request on stdin, key on fd 3),
// apply <rules> <response> <request> <allowed-harnesses-json>.
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
type Route = { agent: AgentRoute; model: ModelRoute; effort_score: number; escalate?: string };
type Filtered = { profile: Profile; reason: string };
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
function prepare(cfg: Config, task: string, project: string): SystemOneRequest {
  const criteria: Record<string, string> = Object.fromEntries(cfg.rules.map((rule, i) => [`rule_${i + 1}`, rule.when]));
  criteria.default = "No listed rule applies to this task.";
  return { model: "jev-latest", state: { task, repository: project }, questions: {
    rule: choice("Which ONE dispatch rule best fits `task` in `repository`? Pick default when no listed condition is met, including exemptions.", criteria),
    ...agentQuestions, ...modelQuestions,
  }};
}
try {
  if (action === "prepare") {
    const [rulesPath, taskPath, project] = args;
    console.log(JSON.stringify(prepare(config(rulesPath), readFileSync(taskPath, "utf8"), project)));
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
    const [rulesPath, responsePath, requestPath, allowedJson] = args;
    const cfg = config(rulesPath);
    const request: unknown = JSON.parse(readFileSync(requestPath, "utf8"));
    validateRequest(request);
    const allowed: unknown = JSON.parse(allowedJson);
    if (!Array.isArray(allowed) || !allowed.every((h: unknown) => typeof h === "string")) throw new Error("allowed");
    const response: unknown = JSON.parse(readFileSync(responsePath, "utf8"));
    validateResponse(response, request.questions);
    const a = response.answers;
    if (a.profile.type !== "choice" || a.ambiguity.type !== "score" || a.needs_desktop.type !== "noul" ||
      a.model.type !== "choice" || a.effort.type !== "score") throw new Error("answer");
    const agent = decideAgent(a.profile, a.ambiguity, a.needs_desktop);
    const route: Route = { agent, model: decideModel(a.model, a.effort), effort_score: a.effort.score };
    if (agent.profile === "human" || a.ambiguity.score > 1 || agent.needsDesktopAccess || agent.profile === "browser_agent" || agent.profile === "deterministic_script") {
      route.escalate = a.ambiguity.score > 1 ? "high task ambiguity requires firstmate judgment" : `${agent.profile} requires an explicit handler or capability decision`;
    }
    const cheap = (p: Profile) => /(?:haiku|luna)/i.test(p.model ?? "");
    const mapProfiles = (use: Profile[]) => {
      const filtered: Filtered[] = [];
      const keep = (ps: Profile[], ok: (p: Profile) => boolean, reason: string) =>
        ps.filter(p => ok(p) || (filtered.push({ profile: p, reason }), false));
      let ps = keep(use, p => allowed.includes(p.harness), "session launch policy prohibits this harness");
      if (route.model.model === "powerful") ps = keep(ps, p => !cheap(p), "Level 5 model router chose powerful, which excludes Haiku/Luna");
      return { use: ps.map(p => {
        if (!p.effort || p.effort === "ultra") return p;
        const effort = /haiku/i.test(p.model ?? "") ? "max" : levels[Math.max(levels.indexOf(p.effort), levels.indexOf(route.model.effort))];
        return { ...p, effort };
      }), filtered };
    };
    cfg.rules = cfg.rules.map(r => ({ ...r, ...mapProfiles(r.use) }));
    const fallback = mapProfiles(cfg.default);
    cfg.default = fallback.use;
    cfg.default_filtered = fallback.filtered;
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
