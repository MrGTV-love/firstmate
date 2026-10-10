import test from "node:test";
import assert from "node:assert/strict";
import * as l3 from "../src/levels/level03/index.ts";
import type { ScoreAnswer } from "../src/core/types.ts";

function scoreAnswer(score: number, levels: number, confidence = 0.9): ScoreAnswer {
  return {
    type: "score",
    score,
    legend: Object.fromEntries(Array.from({ length: levels }, (_, i) => [String(i), `level ${i}`])),
    probabilities: {},
    confidence,
  };
}

test("L3: normalized() maps each scale to 0-1 regardless of level count", () => {
  assert.equal(l3.normalized(scoreAnswer(2, 3)), 1);
  assert.equal(l3.normalized(scoreAnswer(0, 3)), 0);
  assert.equal(l3.normalized(scoreAnswer(2, 4)), 2 / 3);
});

test("L3 A: combinePriority applies the visible weights exactly", () => {
  const { priority, parts } = l3.combinePriority({
    severity: scoreAnswer(2, 3),      // 1.0
    frustration: scoreAnswer(1, 3),   // 0.5
    report_quality: scoreAnswer(2, 4) // 0.667
  });
  const expected = 0.6 * 1 + 0.3 * 0.5 + 0.1 * (2 / 3);
  assert.ok(Math.abs(priority - expected) < 0.01);
  assert.equal(parts.severity, 1);
});

test("L3 A: ticketPriority runs end-to-end and lands in [0,1]", async () => {
  const { priority } = await l3.ticketPriority(
    "Checkout is broken for all customers, no workaround, losing revenue, repro included."
  );
  assert.ok(priority >= 0 && priority <= 1);
});

test("L3 B: codeReviewRisk flags an auth-surface diff for human review", async () => {
  const { needsHumanReview } = await l3.codeReviewRisk(
    "+ if (!token.valid) return unauthorized; session handling rewrite in auth/token.ts",
    "fix session token validation"
  );
  assert.equal(needsHumanReview, true);
});

test("L3 C: ideaVerdict returns kill / fix / ship from weighted dimensions", async () => {
  const v = await l3.ideaVerdict(
    "A decision-model gateway in front of every LLM call that routes, gates, and verifies. Companies already pay per call today."
  );
  assert.ok(["kill", "fix", "ship"].includes(v.verdict));
  assert.ok(v.score >= 0 && v.score <= 1);
});
