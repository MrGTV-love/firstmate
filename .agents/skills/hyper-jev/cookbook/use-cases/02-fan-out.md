# 02. Fan-out on one state

[Catalog and runtime setup](README.md). Demonstrations only, not calibrated production policies.

Use several independent questions in one Jev request when a decision needs multiple signals about the same input. This is question fan-out, not parallel external actions. Application code combines the answers.

## Three implementations

- **[triageTicket](../../templates/starter/src/levels/level02/support-triage.ts)**: ticket -> category Choice, blocked Noul, frustration Score with three levels -> `{ route, priority }`. Category maps `bug_report` to engineering, billing to billing, `feature_request` to product, and other to human. Priority is high when blocked `> 0.5` **or** frustration `> 1.5`, independently of route. Use for queue assignment; no reply or ticket mutation occurs.
- **[screenResume](../../templates/starter/src/levels/level02/resume-screening.ts)**: resume + job description -> distributed-systems Noul, seniority Score, job-fit Score -> `{ proceed, signals }`. `distributed` means Noul `> 0.5`, `senior` means seniority `>= 1.5`, and `proceed` requires fit `> 1.0` plus seniority. Distributed experience is reported but is **not** required by the proceed rule. Use as review assistance, not an autonomous hiring decision.
- **[qualifySponsorForm](../../templates/starter/src/levels/level02/sponsor-qualification.ts)**: name/description/opportunity -> sponsor Noul, product-category Choice, specificity Score -> `{ autoReply, isSponsor, category, specificity }`. Sponsor means `> 0.8`; auto-reply also requires `dev_tool` and specificity `>= 1.5`. Other categories are `course` and `unrelated`. `opportunity` is passed as state but has no explicit policy condition. Use to propose a templated response or manual review.

## Try it

Save as `example.ts` in the starter root. The proposed route and priority can later feed an authenticated ticket service.

```ts
import { triageTicket } from "./src/levels/level02/support-triage.ts";

const decision = await triageTicket(
  "Export button crashes settings page in Safari. Steps: click Export, app freezes. Works in Chrome."
);
console.log({ proposedAssignment: decision });
```

```bash
JEV_BACKEND=mock node example.ts
npm test
```

## Boundaries and tests

[Existing tests](../../templates/starter/tests/level02.test.ts) cover engineering, billing, and product routing; route/priority membership; resume signals; and concrete/vague sponsorship inquiries. They do not fully exercise the priority truth table or every proceed/auto-reply boundary.

Add pure policy tests for blocked-only, frustrated-only, neither, and both. Exercise equality at blocked `0.5`, frustration `1.5`, seniority `1.5`, fit `1.0`, sponsor `0.8`, and specificity `1.5`. Test unknown or malformed answers and provider errors before performing any downstream action. Separate these from labeled semantic evaluations.

## Production policy

- Do not mistake three answers for three independent confirmations. They share a model and context; errors may correlate.
- The triage wrapper returns only route and priority, discarding scores, confidence, and the client result. Preserve `{ decision, result, policyVersion }` in an adapted service, as in [routeSupport](../../templates/starter/src/decisions/support-routing.ts), to retain answers, `raw`, usage, and `meta.cost` for restricted audit and telemetry.
- Resume screening requires job-related criteria, bias evaluation, privacy controls, and meaningful human review. Do not infer protected traits or auto-reject from this demo.
- Auto-reply still needs consent/spam rules, recipient validation, an approved template, and idempotency. No sample sends mail. Source comments about sponsor tuning are anecdotal observations, not production calibration.
