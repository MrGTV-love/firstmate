import test from "node:test";
import assert from "node:assert/strict";
import * as l4 from "../src/levels/level04/index.ts";
import type { ChoiceAnswer, NoulAnswer, ScoreAnswer } from "../src/core/types.ts";

function choiceAnswer(choice: string, confidence: number): ChoiceAnswer {
  return { type: "choice", choice, probabilities: { [choice]: confidence }, confidence };
}
function noulAnswer(noul: number): NoulAnswer {
  return { type: "noul", noul };
}
function scoreAnswer(score: number, levels: number, confidence: number): ScoreAnswer {
  return {
    type: "score",
    score,
    legend: Object.fromEntries(Array.from({ length: levels }, (_, i) => [String(i), `l${i}`])),
    probabilities: {},
    confidence,
  };
}

test("L4 A: below the review floor, everything routes to a human", () => {
  const d = l4.decideAccountAction(choiceAnswer("check_balance", 0.3));
  assert.deepEqual(d, { kind: "human", reason: "low confidence (0.30)" });
});

test("L4 A: a destructive action only auto-runs above the 0.9 bar", () => {
  const confirm = l4.decideAccountAction(choiceAnswer("approve_transfer", 0.8));
  assert.equal(confirm.kind, "confirm");
  const auto = l4.decideAccountAction(choiceAnswer("approve_transfer", 0.95));
  assert.equal(auto.kind, "auto");
});

test("L4 A: a benign action auto-runs above the floor", () => {
  const d = l4.decideAccountAction(choiceAnswer("check_balance", 0.7));
  assert.equal(d.kind, "auto");
});

test("L4 B: an ambiguous rm -rf reproduces the shadow-test escalation", () => {
  // The field result: irreversible at ~0.56 probability, confidence ~0.33 -> ask a human.
  const d = l4.decideCommandSafety(
    choiceAnswer("irreversible", 0.33),
    noulAnswer(0.3),
    noulAnswer(0.6)
  );
  assert.equal(d.requiresHuman, true);
  assert.equal(d.run, false);
});

test("L4 B: a read-only command with decent confidence runs unattended", () => {
  const d = l4.decideCommandSafety(
    choiceAnswer("read_only", 0.8),
    noulAnswer(0.1),
    noulAnswer(0.05)
  );
  assert.equal(d.run, true);
  assert.equal(d.requiresHuman, false);
});

test("L4 B: end-to-end: rm -rf node_modules && npm install is irreversible", async () => {
  const d = await l4.gateShellCommand("rm -rf node_modules && npm install", "/repo");
  assert.equal(d.classification, "irreversible");
  assert.equal(d.run, false);
});

test("L4 C: a faithful quote with a supporting context is supported", () => {
  const d = l4.decideCitation(
    choiceAnswer("supports", 0.8),
    scoreAnswer(2, 3, 0.9)
  );
  assert.equal(d.supported, true);
  assert.equal(d.flagForReview, false);
});

test("L4 C: low confidence flags for human review even when the choice is supports", () => {
  const d = l4.decideCitation(
    choiceAnswer("supports", 0.4),
    scoreAnswer(2, 3, 0.9)
  );
  assert.equal(d.flagForReview, true);
});
