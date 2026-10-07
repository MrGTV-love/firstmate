import { JevClient } from "./core/client.ts";
import { routeSupport } from "./decisions/support-routing.ts";
import { UsageLedger } from "./usage-ledger.ts";

// Construct after environment loading. No keys means an error, not a fake decision.
const client = new JevClient();
const ledger = new UsageLedger();
const message = process.argv[2] ?? "The API crashes and the integration returns errors.";

try {
  const { decision, result, policyVersion } = await routeSupport(client, message, {
    signal: AbortSignal.timeout(10_000),
  });
  ledger.record(result);
  // Raw bodies remain on result for restricted audit storage. Do not print customer data.
  console.log(JSON.stringify({ decision, policyVersion, meta: result.meta, usage: result.usage, totals: ledger.snapshot() }, null, 2));
} catch (error) {
  ledger.recordFailure();
  // An unavailable classifier does not invent a route or authorize a side effect.
  console.error(JSON.stringify({
    decision: { route: "human", reason: "Classification unavailable" },
    error: error instanceof Error ? error.name : "UnknownError",
  }));
  process.exitCode = 1;
}
