import test from "node:test";
import assert from "node:assert/strict";
import * as l10 from "../src/levels/level10/index.ts";
import { JevToolkit } from "../src/levels/level10/index.ts";
import { LIMITS } from "../src/core/types.ts";

test("L10: buildChoiceBlock slugifies and dedupes agent-supplied option keys", () => {
  const t = new JevToolkit();
  const block = t.buildChoiceBlock("Pick a route.", ["Fast Agent", "fast agent", "Reasoning/Agent!", ""]);
  assert.deepEqual(Object.keys(block.criteria), ["fast_agent", "fast_agent_2", "reasoning_agent"]);
});

test("L10: buildChoiceBlock enforces the 255-option cap on dynamic blocks", () => {
  const t = new JevToolkit();
  const many = Array.from({ length: LIMITS.MAX_CHOICE_OPTIONS + 1 }, (_, i) => `opt ${i}`);
  assert.throws(() => t.buildChoiceBlock("Pick.", many), /255/);
});

test("L10: gate() maps confidence to auto / confirm / human", () => {
  const t = new JevToolkit();
  const a = (confidence: number) => ({ type: "choice" as const, choice: "x", probabilities: { x: confidence }, confidence });
  assert.equal(t.gate(a(0.3)).valueOf(), "human");
  assert.equal(t.gate(a(0.7)).valueOf(), "confirm");
  assert.equal(t.gate(a(0.95)).valueOf(), "auto");
});

test("L10 A: a force-push gets a dynamically-built block that blocks it", async () => {
  const g = await l10.gateAgentCommand("git push --force origin main", "/repo");
  assert.equal(g.classification, "rewrites_git_history");
  assert.equal(g.run, false);
  assert.ok(g.detected.includes("pushes_commits"));
  assert.ok(g.detected.includes("rewrites_git_history"));
  assert.ok(g.confidence > 0.5);
});

test("L10 A: a read-only command passes the agent-authored gate", async () => {
  const g = await l10.gateAgentCommand("git status", "/repo");
  // The agent detected a pure read; the dynamic block classified it as such.
  assert.equal(g.classification, "pure_read");
  assert.equal(g.run, true);
  assert.equal(g.gate, "auto");
});

test("L10 A: the option set differs per command — that is the dynamic part", () => {
  const read = l10.buildCommandChoiceBlock("git status", "/repo");
  const net = l10.buildCommandChoiceBlock("curl https://api.example.com/health", "/repo");
  assert.equal(read.detected.includes("network_access"), false);
  assert.equal(net.detected.includes("network_access"), true);
  // Baseline rubric options always exist; detected ones are additive.
  assert.ok("read_only" in read.question.criteria);
  assert.ok("network_access" in net.question.criteria);
});

test("L10 B: the agent-authored router picks the right target", async () => {
  const r = await l10.routeTaskWithAuthoredBlock(
    "Fix the flaky checkout test; a localized change",
    [
      { key: "fast_agent", description: "A quick coding agent for localized changes like fixing a test" },
      { key: "reasoning_agent", description: "Deep reasoning model for architecture work" },
      { key: "human", description: "Judgment, sensitive, or ambiguous work" },
    ]
  );
  assert.equal(r.target, "fast_agent");
  assert.ok(["auto", "confirm", "human"].includes(r.gate));
});

test("L10 C: the review rubric is derived from what the diff actually touches", async () => {
  const j = await l10.judgePullRequest({
    filesChanged: 3,
    linesAdded: 40,
    linesDeleted: 12,
    touches: ["src/auth/session.ts", "migrations/0042_add_tokens.sql"],
    commitMessage: "rotate session tokens on login",
  });
  assert.ok(j.derivedRisks.includes("auth_surface"));
  assert.ok(j.derivedRisks.includes("data_migration"));
  assert.ok(["auto", "confirm", "human"].includes(j.gate));
  assert.ok(j.effort >= 0 && j.effort <= 2);
});
