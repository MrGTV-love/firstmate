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

test("write: lexical roots reject escapes and the root itself", () => {
  assert.equal(l6.insideRepo("docs/x.md", "/repo"), true);
  assert.equal(l6.insideRepo("../x.md", "/repo"), false);
  assert.equal(l6.insideRepo("/repo", "/repo"), false);
});

for (const [probability, expected] of [
  [0, "clear"], [0.2, "clear"], [0.200001, "review"], [0.799999, "review"], [0.8, "flag"], [1, "flag"],
] as const) {
  test(`injection: ${probability} yields ${expected}`, () => {
    const decision = l6.screenResult({ injection: noulA(probability) });
    assert.equal(decision.decision, expected);
  });
}

for (const [name, answer] of [
  ["missing", {}], ["null", { injection: null }], ["wrong type", { injection: { type: "choice", noul: 0 } }],
  ["string", { injection: { type: "noul", noul: "0.2" } }], ["negative", { injection: noulA(-0.01) }],
  ["above one", { injection: noulA(1.01) }], ["NaN", { injection: noulA(NaN) }], ["infinite", { injection: noulA(Infinity) }],
] as const) {
  test(`injection: ${name} is an error, not clear or ambiguous`, () => {
    assert.throws(() => l6.screenResult(answer), { name: "ContractError" });
  });
}

test("empty output is clear without an invented model probability or provider call", async () => {
  let called = false;
  const decision = await l6.screenToolResult("bash", "   \n", async () => { called = true; return { answers: {} }; });
  assert.equal(called, false);
  assert.deepEqual(decision, { decision: "clear", noul: null });
});
