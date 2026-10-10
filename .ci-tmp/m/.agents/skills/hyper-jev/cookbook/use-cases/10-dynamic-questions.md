# 10. Dynamic questions

[Catalog and runtime setup](README.md). Demonstrations only, not calibrated production policies.

Use runtime evidence to construct the option set when routes, tools, or risk categories vary by request. The bundled examples build questions with deterministic code; they do not require an authoring model, a running agent, or external discovery services. Code still defines which options may cause effects.

## Three implementations

- **[buildCommandChoiceBlock / gateAgentCommand](../../templates/starter/src/levels/level10/command-gate.ts)**: command + cwd -> baseline risk options plus regex-detected behaviors -> dynamic risk Choice + ambiguity Noul -> `AgentGate`. Detectors cover pushes, history rewrites, deletion, network, installs, infrastructure, and reads. Ambiguity Noul `> 0.5` resolves the gate to human before execution flags are computed. `run` requires the final gate to be auto and classification `read_only` or `pure_read`; ambiguity therefore sets `run: false` and `requiresConfirmation: true`. Use as a proposal for command review, not as a shell parser or enforcement engine.
- **[authorRouterBlock / routeTaskWithAuthoredBlock](../../templates/starter/src/levels/level10/authored-router.ts)**: caller-supplied target keys/descriptions -> dynamic Choice -> `{ target, confidence, gate }` for a task. Thresholds are floor `0.55`, bar `0.85`. Use when the application discovers eligible destinations; discovery and permission checks are not implemented here.
- **[buildReviewRubric / judgePullRequest](../../templates/starter/src/levels/level10/review-rubric.ts)**: file/line counts, touched paths, commit message -> derived auth/migration/secrets/deletion options plus routine/human options, and an effort Score -> `{ reviewClass, effort, gate, derivedRisks }`. Deletion risk is added when deleted lines exceed twice added lines. Gate thresholds are `0.6` and `0.85`. Use to propose review assignment; only diff metadata, not patch content, is provided.

## Shared toolkit

[JevToolkit](../../templates/starter/src/levels/level10/toolkit.ts) provides `buildChoiceBlock`, `ask`, and `gate`. The builder lowercases/slugifies keys, skips empty slugs, suffixes collisions (`fast_agent_2`), and rejects more than 255 surviving options. `ask` validates questions before transport and returns only `{ answers, usage }`, dropping the client's `raw` and `meta` fields, including cost. Preserve the complete result in a production adapter when audit or telemetry requires it. A builder can still return an empty/invalid block; validation is not complete until `ask` or an explicit `validateQuestions` call.

`gate` returns human below floor, confirm below bar, and auto at or above bar. Default thresholds are `0.5`/`0.9`; equality at bar is auto, unlike the account transfer's strict `> 0.9` rule in level 4. Validate finite ordered thresholds yourself.

## Try it

Save as `example.ts` in the starter root. Already-normalized unique keys keep the selected target aligned with the application registry.

```ts
import { routeTaskWithAuthoredBlock } from "./src/levels/level10/authored-router.ts";

const targets = [
  { key: "fast_agent", description: "Localized changes such as fixing a flaky test" },
  { key: "human", description: "Sensitive or ambiguous work needing human judgment" },
];
const decision = await routeTaskWithAuthoredBlock("Fix the flaky checkout test", targets);
if (!targets.some((t) => t.key === decision.target)) throw new Error("Unknown target");
console.log({ proposedRoute: decision });
```

```bash
JEV_BACKEND=mock node example.ts
npm test
```

## Boundaries and tests

[Existing tests](../../templates/starter/tests/level10.test.ts) cover key normalization/collisions, option cap, gate bands, force-push/read classifications, changing option sets, routing, and derived review risks. Add all-empty options, invalid instructions, normalization-to-ID mapping, exact thresholds, negative/nonfinite diff counts, and untrusted target descriptions.

The bundled fixes are covered by [starter regression tests](../../templates/starter/tests/starter-regressions.test.ts), included in `npm test`:

- An ambiguous command with a confident read-only classification returns `gate: "human"`, `run: false`, and `requiresConfirmation: true`. Escalation is resolved before both execution-related flags.
- Review-class and effort instructions reference the supplied `diff_shape`; the review-class question also references `commit_message` and `touched_paths`. The regression asserts the `diff_shape` references in both questions. This checks field alignment, not live semantic accuracy.

## Production policy

Confidence is not authorization. An auto gate means confidence passed a threshold, not that the review class or route is safe. In particular, `needs_human_judgment` can have gate auto; honor the class itself. Regex-discovered command effects can miss shell expansion, redirects, aliases, and compound behavior; retain deterministic command restrictions and approvals.

Store a reversible map from normalized option keys to authorized runtime IDs; the toolkit does not return that map. Bound discoveries and reject ambiguous/colliding identifiers before building. Preserve question, derived options, evidence, model, and policy versions for audit. Dynamic criteria are a changing policy surface and require the same review and evaluation as handwritten criteria.
