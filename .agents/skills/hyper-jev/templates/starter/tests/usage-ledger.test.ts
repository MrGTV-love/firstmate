import test from "node:test";
import assert from "node:assert/strict";
import { JevClient, type SystemOneResult } from "../src/core/client.ts";
import { noul } from "../src/core/helpers.ts";
import { UsageLedger } from "../src/usage-ledger.ts";

test("ledger separates reported, estimated, unknown, failed, and simulated calls", async () => {
  const mock = await new JevClient({ provider: "mock" }).systemOne("hello", { greeting: noul("Is this a greeting?") });
  const live = (cost: SystemOneResult["meta"]["cost"]): SystemOneResult => ({
    ...mock,
    usage: { input_tokens: 100, output_tokens: 10 },
    meta: { ...mock.meta, provider: "typesafe", attempts: 2, cost },
  });
  const ledger = new UsageLedger();
  ledger.record(mock);
  ledger.record(live({ amount: 0.01, source: "reported" }));
  ledger.record(live({ amount: 0, source: "reported" }));
  ledger.record(live({ amount: 0.02, source: "estimated" }));
  ledger.record(live({ amount: null, source: "unknown" }));
  ledger.recordFailure();
  assert.deepEqual(ledger.snapshot(), {
    successfulLiveCalls: 4, failedCalls: 1, mockCalls: 1,
    attemptsOnSuccessfulLiveCalls: 8,
    inputTokens: 400, outputTokens: 40,
    reportedUsd: 0.01, estimatedUsd: 0.02, unknownCostCalls: 1,
  });
  const snapshot = ledger.snapshot();
  snapshot.reportedUsd = 99;
  assert.equal(ledger.snapshot().reportedUsd, 0.01);
});
