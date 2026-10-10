---
name: hyper-jev
description: Integrate and use Jev, TypeSafe AI's System One decision model, in production codebases. Use for hyper-jev, Jev setup or deployment, TypeSafe/OpenRouter decision APIs, noul/choice/score questions, classifiers, routing, confidence gates, guardrails, dynamic options, retries, cost tracking, and raw payload retention. Includes a portable TypeScript client, tested examples, and a Jev cookbook. Not a presentation or UI-generation skill.
argument-hint: request prompt
---

# Hyper Jev

## Purpose

Turn the user's request into a small, tested Jev integration. Jev evaluates a state against bounded questions and returns typed answers. Your application owns calculations, permissions, thresholds, and execution.

This skill packages the Jev core and thirty examples from the ten-levels codebase. Deploy means integrate the hosted API into the user's backend, not self-host model weights. No slide decks, web lab, visualizations, or agent runtime are required.

## Instructions

- Treat `$ARGUMENTS` as the user's request prompt. Infer the task from the conversation if arguments are absent. Ask only for a missing detail that changes the implementation.
- Resolve bundled paths relative to this `SKILL.md`, not the target project's working directory. The entire skill is portable and lives in `.claude/skills/hyper-jev/`.
- For explanation-only requests, answer without changing files. For implementation, inspect the destination backend, package manager, configuration, tests, and existing conventions before editing.
- Reuse [the bundled client](templates/starter/src/core/client.ts), [types](templates/starter/src/core/types.ts), [builders](templates/starter/src/core/helpers.ts), and their sibling dependencies. Do not invent a chat-completions adapter or a second Jev transport.
- Select the provider once per client instance. Prefer `TYPESAFE_API_KEY`, otherwise `OPENROUTER_API_KEY`. Explicit provider overrides are supported. Never switch providers because of a failed request. Missing credentials must not silently turn production decisions into mock results.
- Keep keys on the server. Do not print credentials, include Authorization headers in audit records, or send sensitive state to a provider without an approved data policy.
- Preserve the complete client result through the service boundary. Business decisions are derived views, not replacements for the raw request, raw response, usage, model ID, and metadata.
- Keep each use case's questions, thresholds, and pure policy function together. Ask independent questions in one call. Make another request only when its state or choices depend on the preceding answer.
- Use Jev for bounded judgments, not arithmetic, date comparisons, unrestricted text generation, or authorization. Security gates are an additional signal, never the only control.
- Copy only the runtime core and requested use cases into an existing app. The thirty-example starter is a reference, not a requirement to add every example.
- Keep changes at the requested scope. Do not deploy infrastructure, make paid calls, modify unrelated modules, or commit unless requested.

## Workflow

1. **Identify the decision.** State the input, allowed outcomes, uncertainty path, and any side effects. Choose Noul for a yes/no probability, Choice for a finite label, or Score for an ordered rubric.
2. **Read the relevant cookbook.** Start with [the index](cookbook/README.md). Read [structure and setup](cookbook/01-structure-and-setup.md), [input/output](cookbook/02-input-output.md), and [client operations](cookbook/04-client-operations.md) for a new integration. Use [question design](cookbook/03-question-design.md), [production checks](cookbook/05-production.md), and only the needed [use-case guides](cookbook/use-cases/README.md).
3. **Place the code.** For a new service, copy [the standalone starter](templates/starter/README.md) into a new directory. In an existing app, adapt `src/core/` to its backend integration folder and add a named decision module. Preserve the client's provider, retry, contract, raw-payload, and cost behavior.
4. **Initialize once.** Load environment configuration before construction. Create one shared client per process or dependency-injection scope. Verify the selected provider name, not the key. Use an explicit mock only in development and tests. Construct a new client to rotate a key.
5. **Define the contract.** Minimize state. Describe each criterion as an observable situation. Give open-ended choices an `other` outcome. Keep option IDs stable and map them to allowed code paths. Validate untrusted requests before sending.
6. **Apply policy in code.** Narrow answer types. Distinguish selected class from confidence. Preserve an explicit review path for ambiguity or outages. Retain the result alongside the decision, following [the starter service](templates/starter/src/decisions/support-routing.ts).
7. **Test offline first.** Run the bundled tests and new boundary tests. Use mocked HTTP responses to test provider selection, retries, malformed responses, raw retention, and accounting without sending data or spending money. The deterministic mock tests wiring, not model accuracy.
8. **Prepare for production.** Calibrate on labeled domain examples. Review credentials, request size, deadlines, concurrency, budget, audit retention, and side-effect permissions. Run a real API smoke test only when authorized, then report the provider and resolved model actually observed.

## Examples

**`/hyper-jev add Jev support triage to our Node API`**

Inspect the API service. Reuse the client, fan out category/blocked/frustration questions, add a review outcome, return `{ decision, result }`, and test routes separately from transport.

**`/hyper-jev explain noul vs choice vs score with inputs and outputs`**

Read the input/output and question-design guides. Show one concrete payload and explain which decisions belong in code. Do not scaffold files.

**`/hyper-jev gate agent tool calls and track their cost`**

Use the guardrails guide. Combine deterministic tool permissions with a risk classification and review path. Keep all probabilities and wire bodies. Separate reported charges, estimates, and unknown cost.

**`/hyper-jev classify documents across 2,000 categories`**

Use the high-cardinality guide. Prune or traverse a taxonomy rather than exceeding 255 choices. Bound depth, requests, and spend. Preserve candidates' real IDs and treat path scores as ranking signals.

## Report Format

Report the implemented decision and file paths, selected provider behavior, tests actually run, and remaining production checks. Distinguish offline contract tests from live validation. Do not describe a mock run as a successful live deployment.
