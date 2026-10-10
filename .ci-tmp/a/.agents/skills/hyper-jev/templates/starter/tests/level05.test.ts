import test from "node:test";
import assert from "node:assert/strict";
import * as l5 from "../src/levels/level05/index.ts";
import type { ChoiceAnswer, NoulAnswer, ScoreAnswer } from "../src/core/types.ts";

function choiceAnswer(choice: string, confidence: number): ChoiceAnswer {
  return { type: "choice", choice, probabilities: { [choice]: confidence }, confidence };
}
function scoreAnswer(score: number, levels: number): ScoreAnswer {
  return {
    type: "score",
    score,
    legend: Object.fromEntries(Array.from({ length: levels }, (_, i) => [String(i), `l${i}`])),
    probabilities: {},
    confidence: 0.9,
  };
}
function noulAnswer(noul: number): NoulAnswer {
  return { type: "noul", noul };
}

test("L5 A: an order-status question routes to lookup, no LLM involved", async () => {
  const r = await l5.routeIntent("Where is my order A-104? Has it shipped yet?");
  assert.equal(r.handler, "lookup");
});

test("L5 A: unclear intent below 0.5 confidence goes to a human", () => {
  const r = l5.decideIntent(choiceAnswer("order_status", 0.4), scoreAnswer(0, 3));
  assert.equal(r.handler, "human");
});

test("L5 A: a hard complaint routes to a human, an easy one to the LLM", () => {
  const hard = l5.decideIntent(choiceAnswer("complaint", 0.8), scoreAnswer(2, 3));
  assert.equal((hard as { handler: string }).handler, "human");
  const easy = l5.decideIntent(choiceAnswer("complaint", 0.8), scoreAnswer(0, 3));
  assert.equal((easy as { handler: string }).handler, "llm");
});

test("L5 B: routeModel picks fast vs powerful with an effort read", async () => {
  const simple = await l5.routeModel("Look up the refund policy in the docs and summarize it in one line");
  assert.equal(simple.model, "fast");
  const hard = await l5.routeModel("Refactor the auth middleware architecture for rotating keys across services; high-stakes decisions");
  assert.equal(hard.model, "powerful");
});

test("L5 C: a localized test fix routes to the fast agent", async () => {
  const r = await l5.routeAgent("Fix the flaky checkout test; a localized change adding a wait", "payments");
  assert.equal(r.profile, "fast_agent");
});

test("L5 C: low-confidence profile decisions escalate to human", () => {
  const r = l5.decideAgent(choiceAnswer("fast_agent", 0.3), scoreAnswer(1, 3), noulAnswer(0.1));
  assert.equal(r.profile, "human");
});
