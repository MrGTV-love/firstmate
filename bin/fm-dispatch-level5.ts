// Firstmate dispatch policy. CLI: validate <rules> (exit 65 for a malformed
// schema); prepare <rules> <task>
// <project> <ship|scout>; call (request on stdin, key on fd 3); apply <rules>
// <response> <request> <allowed-harnesses-json> <cheap-class-re> <max-effort-re>.
import { readFileSync, writeFileSync } from "node:fs";
import { JevClient, ContractError, validateResponse } from "./ten-levels/src/core/client.ts";
import { noul } from "./ten-levels/src/core/helpers.ts";
import { validateRequest } from "./ten-levels/src/core/types.ts";
import { agentQuestions } from "./ten-levels/src/levels/level05/agent-router.ts";
import { modelQuestions, decideModel } from "./ten-levels/src/levels/level05/model-router.ts";
import type { ModelRoute } from "./ten-levels/src/levels/level05/model-router.ts";
import type { NoulQuestion, Questions, SystemOneRequest } from "./ten-levels/src/core/types.ts";

type Profile = Record<string, unknown> & { harness: string; model?: string; effort?: string };
type Match = { project?: string; exclude_project?: string; kind?: "ship" | "scout"; all?: string[]; any?: string[]; none?: string[] };
type Rule = Record<string, unknown> & { when: string; match: Match; use: Profile[] };
type Config = Record<string, unknown> & { judgments: Record<string, NoulQuestion>; rules: Rule[]; default: Profile[] };
type Filtered = { profile: Profile; reason: string };
const [action, ...args] = process.argv.slice(2);
const levels = ["low", "medium", "high", "xhigh", "max"];
const model = "jev-latest";
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
  if (!object(value) || !Array.isArray(value.rules) || !object(value.judgments)) throw new Error("judgments");
  const judgments: Record<string, NoulQuestion> = {};
  for (const [id, q] of Object.entries(value.judgments)) {
    if (!/^[a-z][a-z0-9_]*$/.test(id) || !object(q) || q.type !== "noul" ||
      typeof q.instructions !== "string" || !q.instructions.trim() || !object(q.criteria) ||
      typeof q.criteria.true !== "string" || !q.criteria.true.trim() ||
      typeof q.criteria.false !== "string" || !q.criteria.false.trim()) throw new Error("judgment");
    judgments[id] = noul(q.instructions, { true: q.criteria.true, false: q.criteria.false });
  }
  const rules = value.rules.map((r: unknown) => {
    if (!object(r) || typeof r.when !== "string" || !object(r.match)) throw new Error("rule match");
    const m = r.match;
    if (Object.keys(m).some(k => !["project", "exclude_project", "kind", "all", "any", "none"].includes(k)) ||
      [m.project, m.exclude_project].some(p => p !== undefined && (typeof p !== "string" || !p.trim())) ||
      (m.kind !== undefined && m.kind !== "ship" && m.kind !== "scout")) throw new Error("rule facts");
    for (const key of ["all", "any", "none"]) {
      const ids = m[key];
      if (ids !== undefined && (!Array.isArray(ids) || ids.length === 0 ||
        ids.some(id => typeof id !== "string" || !Object.hasOwn(judgments, id)))) throw new Error("rule judgments");
    }
    return { ...r, when: r.when, match: m as Match, use: profiles(r.use) };
  });
  return { ...value, judgments, rules, default: profiles(value.default) };
}
function eligible(match: Match, project: string, kind: unknown): boolean {
  return (!match.project || project === match.project) &&
    (!match.exclude_project || (!!project && project !== match.exclude_project)) &&
    (!match.kind || kind === match.kind);
}
function prepare(cfg: Config, task: string, project: string, kind: string): SystemOneRequest {
  if (kind !== "ship" && kind !== "scout") throw new Error("kind");
  const questions: Questions = {
    ambiguity: agentQuestions.ambiguity,
    needs_desktop: noul("Does completing `task` require interacting with an authenticated application session or the graphical desktop?", {
      true: "The requested outcome requires operating a logged-in web application, a native GUI application, or the desktop itself.",
      false: "The task can be completed using repository files, a terminal, public web pages, or an API; mentioning a browser, app, or provider without requiring interactive session access is not enough.",
    }),
    ...modelQuestions,
  };
  for (const rule of cfg.rules.filter(r => eligible(r.match, project, kind))) {
    for (const id of [...(rule.match.all ?? []), ...(rule.match.any ?? []), ...(rule.match.none ?? [])]) {
      questions[`judgment_${id}`] = cfg.judgments[id];
    }
  }
  return { model, state: { task, repository: project, kind }, questions };
}
try {
  if (action === "validate") {
    try {
      config(args[0]);
    } catch (error) {
      if (error instanceof Error && "code" in error) throw error;
      console.error("dispatch-level5: malformed rules schema");
      process.exitCode = 65;
    }
  } else if (action === "prepare") {
    const [rulesPath, taskPath, project, kind] = args;
    console.log(JSON.stringify(prepare(config(rulesPath), readFileSync(taskPath, "utf8"), project, kind)));
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
    const [rulesPath, responsePath, requestPath, allowedJson, cheapPattern, maxEffortPattern] = args;
    if (!cheapPattern || !maxEffortPattern) throw new Error("classes");
    const cheapClass = new RegExp(cheapPattern, "i");
    const maxEffort = new RegExp(maxEffortPattern, "i");
    const cfg = config(rulesPath);
    const request: unknown = JSON.parse(readFileSync(requestPath, "utf8"));
    validateRequest(request);
    if (!object(request.state) || typeof request.state.task !== "string" || typeof request.state.repository !== "string" ||
      (request.state.kind !== "ship" && request.state.kind !== "scout")) throw new Error("request facts");
    const allowed: unknown = JSON.parse(allowedJson);
    if (!Array.isArray(allowed) || !allowed.every((h: unknown) => typeof h === "string")) throw new Error("allowed");
    const response: unknown = JSON.parse(readFileSync(responsePath, "utf8"));
    validateResponse(response, request.questions);
    const a = response.answers;
    if (a.ambiguity.type !== "score" || a.needs_desktop.type !== "noul" || a.model.type !== "choice" || a.effort.type !== "score") throw new Error("answer");
    const route: { model: ModelRoute; effort_score: number; ambiguity: number; needsDesktopAccess: boolean; escalate?: string } = {
      model: decideModel(a.model, a.effort), effort_score: a.effort.score,
      ambiguity: a.ambiguity.score, needsDesktopAccess: a.needs_desktop.noul > 0.5,
    };
    if (a.ambiguity.score > 1) route.escalate = "high task ambiguity requires firstmate judgment";
    else if (route.needsDesktopAccess) route.escalate = "desktop access requires an explicit capability decision";
    const { repository, kind } = request.state;
    const support: Record<string, number> = {};
    const judgment = (id: string) => {
      const answer = a[`judgment_${id}`];
      if (answer?.type !== "noul") throw new Error("judgment answer");
      return answer.noul;
    };
    cfg.rules.forEach((r, i) => {
      if (!eligible(r.match, repository, kind)) return;
      support[`rule_${i + 1}`] = Math.min(1, ...(r.match.all ?? []).map(judgment),
        ...(r.match.any ? [Math.max(...r.match.any.map(judgment))] : []),
        ...(r.match.none ?? []).map(id => 1 - judgment(id)));
    });
    // These are fuzzy predicate supports, not a categorical distribution.
    // Never sum overlapping judgments or let an ineligible rule enter fallback.
    support.default = Math.min(1, ...Object.values(support).map(p => 1 - p));
    const choice = Object.keys(support).reduce((best, id) => support[id] > support[best] ? id : best);
    const cheap = (p: Profile) => cheapClass.test(p.model ?? "");
    const mapProfiles = (use: Profile[]) => {
      const filtered: Filtered[] = [];
      const keep = (ps: Profile[], ok: (p: Profile) => boolean, reason: string) =>
        ps.filter(p => ok(p) || (filtered.push({ profile: p, reason }), false));
      let ps = keep(use, p => allowed.includes(p.harness), "session launch policy prohibits this harness");
      if (route.model.model === "powerful") ps = keep(ps, p => !cheap(p), "Level 5 model router chose powerful, which excludes Haiku/Luna");
      return { use: ps.map(p => {
        if (!p.effort || p.effort === "ultra") return { ...p, cheap: cheap(p) };
        const effort = maxEffort.test(p.model ?? "") ? "max" : levels[Math.max(levels.indexOf(p.effort), levels.indexOf(route.model.effort))];
        return { ...p, cheap: cheap(p), effort };
      }), filtered };
    };
    cfg.rules = cfg.rules.map(r => ({ ...r, ...mapProfiles(r.use) }));
    const fallback = mapProfiles(cfg.default);
    cfg.default = fallback.use;
    cfg.default_filtered = fallback.filtered;
    writeFileSync(rulesPath, JSON.stringify(cfg));
    console.log(JSON.stringify({ ...response, route, selection: { choice, confidence: support[choice], support } }));
  } else throw new Error("unknown action");
} catch (error) {
  // Never echo arbitrary API bodies, request text, credentials, or fetch URLs.
  const http = error instanceof Error ? error.message.match(/^typesafe HTTP ([0-9]{3})\./)?.[1] : undefined;
  const category = http ? `TypeSafe HTTP ${http}` : error instanceof ContractError ? "invalid provider answer contract"
    : error instanceof Error && error.name === "TimeoutError" ? "request deadline exceeded" : "request or local policy failure";
  console.error(`dispatch-level5: ${category}`);
  process.exitCode = 1;
}
