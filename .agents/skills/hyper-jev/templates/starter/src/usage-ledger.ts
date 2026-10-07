import type { SystemOneResult } from "./core/client.ts";

/** Process-local observation, not a billing ledger or an enforceable spend limit. */
export class UsageLedger {
  private totals = {
    successfulLiveCalls: 0,
    failedCalls: 0,
    mockCalls: 0,
    attemptsOnSuccessfulLiveCalls: 0,
    inputTokens: 0,
    outputTokens: 0,
    reportedUsd: 0,
    estimatedUsd: 0,
    unknownCostCalls: 0,
  };

  record(result: SystemOneResult): void {
    if (result.meta.provider === "mock") {
      this.totals.mockCalls++;
      return;
    }
    this.totals.successfulLiveCalls++;
    this.totals.attemptsOnSuccessfulLiveCalls += result.meta.attempts;
    this.totals.inputTokens += result.usage.input_tokens;
    this.totals.outputTokens += result.usage.output_tokens;
    const cost = result.meta.cost;
    if (cost.source === "reported") this.totals.reportedUsd += cost.amount;
    else if (cost.source === "estimated") this.totals.estimatedUsd += cost.amount;
    else this.totals.unknownCostCalls++;
  }

  /** Failure charges and tokens are unknown, not zero. */
  recordFailure(): void {
    this.totals.failedCalls++;
  }

  snapshot() {
    return { ...this.totals };
  }
}
