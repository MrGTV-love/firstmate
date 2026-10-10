import test from "node:test";
import assert from "node:assert/strict";
import * as l2 from "../src/levels/level02/index.ts";
import type { ChoiceAnswer, NoulAnswer, ScoreAnswer } from "../src/core/types.ts";

const bug = "Export button crashes settings page in Safari. Steps: click Export, app freezes. Works in Chrome.";
const billing = "You charged my card twice for order A-104. Please refund the duplicate charge.";

test("L2 A: a crashing bug routes to engineering", async () => {
  const t = await l2.triageTicket(bug);
  assert.equal(t.route, "engineering");
});

test("L2 A: a duplicate charge routes to billing", async () => {
  const t = await l2.triageTicket(billing);
  assert.equal(t.route, "billing");
});

test("L2 A: a feature request routes to product", async () => {
  const t = await l2.triageTicket("Feature request: please add a dark mode to the dashboard, it does not exist yet.");
  assert.equal(t.route, "product");
});

test("L2 A: the route is always one of the four teams (type safety)", async () => {
  const t = await l2.triageTicket("Random text with no strong signal for any team.");
  assert.ok(["engineering", "billing", "product", "human"].includes(t.route));
  assert.ok(["high", "normal"].includes(t.priority));
});

test("L2 B: screenResume surfaces distributed + senior signals", async () => {
  const v = await l2.screenResume(
    "10 years building distributed systems at Stripe. Led payments reconciliation. Mentored 6 engineers.",
    "Senior backend engineer. Requirements: distributed systems, payments, mentoring."
  );
  assert.equal(v.signals.distributed, true);
  assert.equal(v.signals.senior, true);
});

test("L2 C: a concrete dev-tool sponsor inquiry qualifies", async () => {
  const q = await l2.qualifySponsorForm({
    name: "Managed Postgres",
    description: "We make managed PostgreSQL hosting and want to sponsor the newsletter in October.",
    opportunity: "link",
  });
  assert.equal(q.isSponsor, true);
  assert.equal(q.category, "dev_tool");
});

test("L2 C: specificity drives the auto-reply decision", async () => {
  const q = await l2.qualifySponsorForm({
    name: "Some Product",
    description: "We would like to sponsor.",
    opportunity: "link",
  });
  // A vague ask should not auto-reply even if it is a sponsor inquiry.
  assert.equal(q.specificity < 1.5 || !q.isSponsor, true);
  assert.equal(q.autoReply, false);
});
