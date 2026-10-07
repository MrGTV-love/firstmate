import test from "node:test";
import assert from "node:assert/strict";
import * as l6 from "../src/levels/level06/index.ts";
import type { ChoiceAnswer, ScoreAnswer } from "../src/core/types.ts";

test("L6 A: watchEditorTone returns all three signals in range", async () => {
  const s = await l6.watchEditorTone(
    "Hey, quick follow up on invoice INV-204: the amount seems wrong, $490 instead of $245. Can we fix it this week?"
  );
  for (const v of [s.tone, s.urgency, s.readsAsAI]) assert.ok(v >= 0 && v <= 2, `${v} in [0,2]`);
});

test("L6 A: a hostile draft triggers the soften_tone suggestion", async () => {
  const s = await l6.watchEditorTone(
    "This is unacceptable and insulting, your team is incompetent, fix it now or we walk."
  );
  assert.equal(s.suggest, "soften_tone");
});

test("L6 B: a genuine question stays, an outrage post hides", async () => {
  const verdicts = await l6.filterFeed([
    { id: "p1", author: "@dev", text: "Genuine question: how do you handle retries in job queues? Sharing my notes." },
    { id: "p2", author: "@rage", text: "Everyone using framework X is insulting and here is why you should be outraged" },
  ]);
  const p1 = verdicts.find((v) => v.id === "p1")!;
  const p2 = verdicts.find((v) => v.id === "p2")!;
  assert.equal(p1.hide, false);
  assert.equal(p2.hide, true);
  assert.equal(p2.reason, "rage_bait");
});

test("L6 C: an enterprise evaluation surfaces the security questionnaire", async () => {
  const r = await l6.adaptiveForm(
    "We are a 400-person company evaluating this for procurement, we need SOC2 and the security questionnaire first."
  );
  assert.ok(r.controls.includes("security_questionnaire"));
  assert.ok(r.controls.includes("pricing_tier"));
});

test("L6 C: decideForm is pure logic — support path always gets free_text only", () => {
  const r = l6.decideForm(
    { type: "choice", choice: "support_issue", probabilities: {}, confidence: 0.9 },
    { type: "score", score: 0, legend: {}, probabilities: {}, confidence: 0.9 }
  );
  assert.deepEqual(r.controls, ["free_text"]);
});
