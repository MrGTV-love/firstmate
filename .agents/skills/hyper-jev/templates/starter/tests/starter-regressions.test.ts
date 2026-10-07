import test from "node:test";
import assert from "node:assert/strict";
import { hierarchicalClassify } from "../src/levels/level09/hierarchical-classify.ts";
import { JevToolkit } from "../src/levels/level10/toolkit.ts";
import { gateAgentCommand } from "../src/levels/level10/command-gate.ts";
import { buildReviewRubric } from "../src/levels/level10/review-rubric.ts";

test("mixed-depth taxonomy retains a completed leaf while expanding its sibling", async () => {
  const result = await hierarchicalClassify("unrelated input", {
    name: "root", description: "root",
    children: [
      { name: "early_leaf", description: "orchids" },
      { name: "branch", description: "telescopes", children: [
        { name: "deep_leaf", description: "cobras" },
      ] },
    ],
  }, 2);
  assert.equal(result.length, 2);
  assert.ok(result.some((r) => r.path.join("/") === "root/early_leaf"));
  assert.ok(result.some((r) => r.path.join("/") === "root/branch/deep_leaf"));
});

test("an ambiguous command cannot run even when its read-only classification is confident", async (t) => {
  t.mock.method(JevToolkit.prototype, "ask", async () => ({
    answers: {
      risk: { type: "choice", choice: "pure_read", confidence: 0.99, probabilities: { pure_read: 1 } },
      ambiguous: { type: "noul", noul: 0.8 },
    },
    usage: { input_tokens: 10, output_tokens: 10 },
  }));
  const result = await gateAgentCommand("git status", "/repo");
  assert.equal(result.gate, "human");
  assert.equal(result.run, false);
  assert.equal(result.requiresConfirmation, true);
});

test("review rubric refers to the state fields the service actually sends", () => {
  const rubric = buildReviewRubric({
    filesChanged: 1, linesAdded: 10, linesDeleted: 0,
    touches: ["src/auth/session.ts"], commitMessage: "change session handling",
  });
  assert.match(String(rubric.block.instructions), /`diff_shape`/);
  assert.match(String(rubric.effort.instructions), /`diff_shape`/);
});
