# 04. Confidence gating

[Catalog and runtime setup](README.md). Demonstrations only, not calibrated production policies.

Use confidence to decide whether a prediction needs confirmation or review. **Confidence is not authorization** and is not a guarantee that the selected action is safe. Authentication, permissions, transaction limits, and effect-specific approvals remain ordinary code.

## Three implementations

- **[routeAccountAction / decideAccountAction](../../templates/starter/src/levels/level04/account-actions.ts)**: message -> Choice among balance, transfer approval, support -> `AccountAction`. Below `0.5`, return human. A transfer is auto only above `0.9`; at `0.9` it still requires confirmation. Other choices are auto at or above `0.5`. This is an intent/UX ladder, not a payment authorization policy; no account operation is executed.
- **[gateShellCommand / decideCommandSafety](../../templates/starter/src/levels/level04/shell-command-gate.ts)**: command + cwd -> risk Choice, outside-repo Noul, destructive-intent Noul -> `{ classification, run, requiresHuman, confidence }`. Only read-only classification with confidence `>= 0.5` sets `run`. Human review is requested for low risk confidence, non-read-only confidence `< 0.9`, or either Noul `> 0.6`.
- **[checkCitation / decideCitation](../../templates/starter/src/levels/level04/citation-check.ts)**: claim + quote + supplied source context -> support Choice and quote-fidelity Score -> `{ supported, flagForReview, confidence }`. Supported requires choice `supports`, support confidence `>= 0.6`, and quote score `>= 1`. Review is flagged if support or quote confidence is `< 0.5`; returned confidence is their minimum. Use to queue citation review, not to certify external facts.

Shared constants live in [confidence.ts](../../templates/starter/src/levels/level04/confidence.ts).

## Try it

Save as `example.ts` in the starter root. This prints a conservative proposal and does not spawn a shell.

```ts
import { gateShellCommand } from "./src/levels/level04/shell-command-gate.ts";

const decision = await gateShellCommand("ls -la", "/repo");
const next = decision.requiresHuman ? "review" : decision.run ? "eligible" : "deny";
console.log({ decision, next });
```

```bash
JEV_BACKEND=mock node example.ts
npm test
```

## Boundaries and tests

[Existing tests](../../templates/starter/tests/level04.test.ts) directly exercise all three pure decision functions plus a destructive shell example. Add exact equality tests at `0.5`, `0.6`, and `0.9`, invalid numeric values, and conflicting signals.

Important source behavior:

- Shell `run` and `requiresHuman` are computed independently. A confident read-only choice plus a high destructive/outside Noul returns **both true**. Human review must override `run`.
- A high-confidence write can return both `run: false` and `requiresHuman: false`. Absence of a review flag is not permission to execute.
- Citation `supported` can be true while `flagForReview` is true because quote confidence is low. Review takes precedence over publication.

## Production policy

Security classifiers must not be the sole safeguards. Parse and allowlist commands/arguments, resolve paths safely, restrict credentials and network access, and use a sandbox. Fail closed or request review on errors. Never execute from `run` alone.

For account transfers, verify actor, account ownership, amount, destination, approval requirements, and idempotency regardless of confidence. For citations, verify provenance, quoted spans, and source retrieval separately. The sample evaluates only the text supplied by the caller.
