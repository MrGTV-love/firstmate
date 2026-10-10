import test from "node:test";
import assert from "node:assert/strict";
import { JevClient } from "../src/core/client.ts";
import type { ChoiceAnswer } from "../src/core/types.ts";
import { decideSupportRoute, routeSupport, REVIEW_FLOOR, MAX_MESSAGE_BYTES } from "../src/decisions/support-routing.ts";

// These fixtures test application policy, not model quality or wire distributions.
const answer = (choice: string, confidence: number): ChoiceAnswer => ({
  type: "choice", choice, confidence, probabilities: { [choice]: 1 },
});

test("policy routes only approved labels and reviews other or unknown labels", () => {
  assert.equal(decideSupportRoute(answer("technical", 0.95)).route, "engineering");
  assert.equal(decideSupportRoute(answer("billing", 0.95)).route, "billing");
  assert.equal(decideSupportRoute(answer("sales", 0.95)).route, "sales");
  assert.equal(decideSupportRoute(answer("other", 0.99)).route, "human");
  assert.equal(decideSupportRoute(answer("arbitrary-handler", 0.99)).route, "human");
});

test("policy tests exact confidence boundary and non-finite input", () => {
  assert.equal(decideSupportRoute(answer("technical", REVIEW_FLOOR - 0.001)).route, "human");
  assert.equal(decideSupportRoute(answer("technical", REVIEW_FLOOR)).route, "engineering");
  assert.equal(decideSupportRoute(answer("technical", Number.NaN)).route, "human");
});

test("service validates input before any client call", async () => {
  const client = new JevClient({ provider: "mock" });
  await assert.rejects(routeSupport(client, " "), TypeError);
  await assert.rejects(routeSupport(client, "a".repeat(MAX_MESSAGE_BYTES + 1)), RangeError);
  await assert.rejects(routeSupport(client, "界".repeat(MAX_MESSAGE_BYTES / 2)), RangeError);
  assert.equal(client.calls, 0);
});

test("service retains the complete client result next to its decision", async () => {
  const client = new JevClient({ provider: "mock" });
  const output = await routeSupport(client, "Broken software crashes and integration errors");
  assert.equal(client.calls, 1);
  assert.equal(output.result.answers.department.type, "choice");
  assert.equal(output.result.meta.provider, "mock");
  assert.ok(output.policyVersion);
  assert.ok(output.result.raw);
});

test("transport failures propagate rather than becoming an automated route", async () => {
  const client = new JevClient({ provider: "mock" });
  client.systemOne = async () => { throw new Error("unavailable"); };
  await assert.rejects(routeSupport(client, "Checkout is broken"), /unavailable/);
});
