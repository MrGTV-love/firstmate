# Source

This directory holds the Level 5 routers and Level 6 policies from disler's ten-levels-of-jev.
Firstmate's worker guard uses those policies and the canonical client through `bin/fm-jev-guard.ts`.

- Repository: https://github.com/disler/ten-levels-of-jev
- Path: `apps/ten-levels` (the `LICENSE` file comes from the repository root)
- Commit: `777adaf47d37ae0553220d35b2f15b3a3a063305` (committed 2026-09-27)
- Vendored: 2026-10-07
- License: MIT, see `LICENSE` in this directory.

## Unmodified copies

These files remain byte-for-byte copies at their upstream paths:

- `src/core/client.ts`, `helpers.ts`, `mock.ts` and `types.ts`
- `src/levels/level06/index.ts` and `bash-gate.ts`
- `src/levels/level05/intent-router.ts` and `index.ts`
- `tests/level05.test.ts`
- `LICENSE`

The guard and `bin/fm-dispatch-level5.ts` import the same `src/core/client.ts`; neither owns a second transport.
Provider snapshots, raw exchange retention, validation, retry behavior and cost certainty remain the canonical client's responsibility.
The [operator contract](../../docs/configuration.md#jev-guard) owns the guard's budgets, egress and host limits.

## Changed copies: Level 5 agent and model routers

Level 5 was copied from the same pinned commit on 2026-10-14 (UTC).
`src/levels/level05/agent-router.ts` exports its existing question object as `agentQuestions`, and `model-router.ts` exports its existing question object as `modelQuestions`.
Their original route functions consume those objects unchanged.
This is the only change in those copies: combining independent agent and model questions in one paid dispatch request requires access to the objects without invoking two separate route calls.
Question wording, criteria, pure decisions, and thresholds remain upstream's.
`bin/fm-dispatch-level5.ts` combines the objects with the existing rule question, uses the unchanged core client, and maps the pure decisions into the approved candidates.

## Changed copies: Level 6 result policy and service

- `src/levels/level06/result-screen.ts` owns the frozen, calibrated injection Noul and pure clear/flag/review policy.
  Invalid answers throw the canonical contract error, empty output invents no probability, and complete result text replaces prefix-only screening.
  The [accepted frozen calibration summary](../../docs/verification/runtime-backends.md#accepted-frozen-live-calibration) owns measured denominators, abstentions, fixture exclusions and estimated-cost uncertainty.
- `src/levels/level06/write-gate.ts` removes prefix-only content assessment and names the existing secrets-file threshold without changing valid shell/write questions or threshold behavior.
- `tests/level06.test.ts` exercises equality boundaries, independent shell/write signals, invalid injection values and empty-output handling instead of pinning banner/reason wording or claiming mock semantic accuracy.
- `extensions/report.ts` is Firstmate's per-installation service and minimized audit owner rather than the upstream lab side channel.
  It snapshots and checks the complete request before key lookup, plans an oversized payload as overlapping pieces that each fit the request ceiling (`plan`), refuses one that no complete cover fits, uses the existing TypeSafe key/privacy owners, keeps the complete successful client result through policy evaluation, and normalizes error types without logging exception payloads.
  Its shared cancellation scope bounds both handlers, and its terminal-record API deliberately excludes raw exchanges, arbitrary provider fields and input-derived text.
  Durable-record failure is explicit rather than silently optional while active.
  It also makes one bounded retry of an outage of a required judgment inside the handler budget, owns the outage-only deny text that replaces the permanent block notice, and records its own tries and elapsed time on failure rows that hold no provider answer.

The obsolete `extensions/jev-guard.ts` lab hook wrapper and its permissive error handling are removed, not retained as a second runtime path.

## Firstmate glue outside this directory

- `bin/fm-jev-guard.ts` is the single worker event entry point and applies deterministic input/root/device checks before model screening.
  It judges every piece of an oversized payload with the unchanged level 6 policies and passes the payload only when every piece passes.
  Its host response handling and one isolated Firstmate-channel consistency function consume the service and pure policies; no signing, alternate transport or tool proxy is introduced.
  The [operator contract](../../docs/configuration.md#jev-guard) owns host-specific result handling, the role-file receipt trust limit (including same-user digest forgery), named outage behavior and explicit no-protection claim; consistency is never producer authentication.
- `bin/fm-jev-guard-claude.ts` forwards actual input/call identity, maps pre-tool refusal to Claude denial, and maps result notices only to advisory `additionalContext`.
  Current Claude documentation describes built-in output replacement, but this adapter does not claim installed-host support or use it without verification.
- `bin/fm-jev-guard-hook.sh` runs the adapter with Bun or Node type stripping and observes its process result so missing or crashed active runtimes require review rather than silently allowing required pre-tool decisions.
  Only successful handler stdout is published; raw failure streams are withheld and the observed exit status is carried in a stable sanitized diagnostic.
- `bin/fm-spawn.sh` remains the launch owner for physical project scope, per-task launch-only guard activation retained on relaunch, context, Claude hook registration, omp extension loading and process-local replace-edit mode.
  Native omp prompt events and Claude's separate prompt/tool hooks bind exact source reads without copying raw prompts into the latter's task/session-local hash context.
- The existing `bin/fm-operational-input.sh` publisher owns write-time consistency metadata; `bin/fm-task-inbox-lib.sh` reuses it and names the exact record in its bounded doorbell.
  The [inbox owner's header](../fm-task-inbox-lib.sh) owns delivery and retry semantics.

[`tests/fm-jev-guard.test.sh`](../../tests/fm-jev-guard.test.sh) exercises the public service and adapters with isolated synthetic HTTP fixtures.
[Native verification](../../docs/verification/runtime-backends.md#jev-guard-native-tool-hooks) distinguishes actual host delivery, controlled decision fixtures, live calibration and deployed acceptance.
