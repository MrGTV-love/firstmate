import test from "node:test";
import assert from "node:assert/strict";
import * as l6 from "../src/levels/level06/index.ts";
import type { ChoiceAnswer, ChoiceCriteria, NoulAnswer } from "../src/core/types.ts";

function choiceA(choice: string, confidence: number, criteria: ChoiceCriteria = l6.BASH_QUESTIONS.effect.criteria): ChoiceAnswer {
  const keys = Object.keys(criteria);
  return { type: "choice", choice, confidence,
    probabilities: Object.fromEntries(keys.map((key) => [key, key === choice ? confidence : (1 - confidence) / (keys.length - 1)])) };
}
const noulA = (p: number): NoulAnswer => ({ type: "noul", noul: p });

test("shell: irreversible equality and destructive equality deny independently", () => {
  for (const [confidence, destructive, block] of [
    [0.5999, 0.6999, false], [0.6, 0.6999, true], [0.5999, 0.7, true],
  ] as const) {
    assert.equal(l6.gateBash({ effect: choiceA("irreversible", confidence), destructive_intent: noulA(destructive) }).block, block);
  }
  assert.equal(l6.gateBash({ effect: choiceA("read_only", 0.95), destructive_intent: noulA(0.02) }).block, false);
  assert.equal(l6.gateBash({ effect: choiceA("reversible", 0.5), destructive_intent: noulA(0.85) }).block, true);
});

test("write: outside-root denial precedes any model call", async () => {
  let called = false;
  const decision = await l6.gateWriteCall("/tmp/notes.txt", "hello", "/repo", async () => { called = true; return { answers: {} }; });
  assert.equal(decision.block, true);
  assert.equal(called, false);
  assert.equal(l6.insideRepo("docs/x.md", "/repo"), true);
  assert.equal(l6.insideRepo("../x.md", "/repo"), false);
  assert.equal(l6.insideRepo("/repo", "/repo"), false);
});

test("write: credential and secrets-file equality preserve independent thresholds", () => {
  for (const [kind, confidence, secret, block] of [
    ["config", 0.8, 0.6999, false], ["config", 0.8, 0.7, true],
    ["secrets", 0.7999, 0.1, false], ["secrets", 0.8, 0.1, true],
  ] as const) {
    assert.equal(l6.gateWrite({ kind: choiceA(kind, confidence, l6.WRITE_QUESTIONS.kind.criteria), contains_secret: noulA(secret) }).block, block);
  }
});
