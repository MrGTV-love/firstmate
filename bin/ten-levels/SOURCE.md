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
- `src/levels/level06/bash-gate.ts` (unused)
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
`bin/fm-dispatch-level5.ts` uses the unchanged model questions, model decision and ambiguity rubric, but owns Firstmate's structured rule predicates, desktop criteria and capability policy outside the vendored copies.
It does not ask or apply the upstream workflow/profile Choice or agent decision.
The [operator contract](../../docs/configuration.md#typed-dispatch-resolution-env-typesafe_api_key) owns that adapter's routing semantics.

## Changed copies: Level 6 policies and service

- `src/levels/level06/index.ts` exports only the write policy.
  `src/levels/level06/result-screen.ts` is unchanged by this ship and unused: no import or call loads it.
  Its Firstmate changes from upstream remain: a frozen, calibrated injection Noul, the canonical contract error on invalid answers, no invented probability for empty output, complete-text instead of prefix-only screening, and the shared `Decide` type imported from `write-gate.ts`.
  The unchanged vendored `bash-gate.ts` is unused: no imports or calls load it.
  Follow-up task `fm-jev-guard-delete-unused-result-screen` deletes both `result-screen.ts` and `bash-gate.ts`; ship T2 already removed the bash model gate.
- `src/levels/level06/write-gate.ts` removes prefix-only content assessment, names the existing secrets-file threshold and owns the shared `Decide` and `GateDecision` types without changing valid write questions or threshold behavior.
- `tests/level06.test.ts` exercises write threshold boundaries and outside-root refusal.
- `extensions/report.ts` is Firstmate's per-installation pre-tool service and minimized audit owner rather than the upstream lab side channel.
  The [operator contract](../../docs/configuration.md#jev-guard) owns its privacy checks, bounded write planner, coverage accounting, failure normalization and cancellation budgets.
  Its terminal records also cover every host tool name and deterministic egress/coverage decisions, retaining only the tool's single destination class from the egress policy, never outbound arguments or destinations.
  Confinement-owned effects record `confinement_owner: T5` before egress authorization, so a compound skill-bearing `learn` retains its write owner even when its memory effect is refused for a missing provider grant.
  This identifies the launch-time enforcement owner and is not proof that confinement is active.
  The canonical client, write questions and thresholds are unchanged.
  There is no result policy, result request budget or result audit path.

The obsolete `extensions/jev-guard.ts` lab hook wrapper and its permissive error handling are removed, not retained as a second runtime path.

## Firstmate glue outside this directory

- `bin/fm-jev-guard.ts` is the single worker pre-tool event entry point and applies deterministic tool coverage, egress authorization and input/root/device checks before model screening.
  `bin/fm-jev-egress.ts` owns the tool classifications and each tool's egress row; the operator contract above owns task grants and the table's non-sandbox limits.
  Native device admission uses the adapter context's host (default `omp`, explicitly `claude` in the Claude adapter), not the model service; host identity remains required even without host-specific result budgets.
  It judges every planned write piece with the unchanged level 6 policy; writes pass only when every planned piece passes.
  Its one shell exception is the deterministic, model-free brief-named deletion record below.
  Its local credential-URL matcher consumes complete scheme-character runs, including punctuation-led runs, so long hyphenated report lines do not repeatedly rescan overlapping suffixes or hide credential URLs.
  Bash pre-calls return without judging effects or destructive intent, planning provider requests, inspecting lab markers or classifying read-only commands; only an omp brief-named deletion record writes audit rows.
  Write/edit refusals record their target and direct an authorized correction; write roots remain worktree, task data and temporary directory only.
  The [operator contract](../../docs/configuration.md#jev-guard) owns enforcement and outage behavior.
- `bin/fm-jev-deletions.ts` owns the deterministic brief-named deletion record for omp `bash` calls, its mandatory task-local audit, and the firstmate-side publisher used by `bin/fm-jev-deletions.sh` and initial spawn.
  The [operator contract](../../docs/configuration.md#brief-named-file-deletion-allowance) owns the literal-shell grammar, HEAD/file/path checks, live update/revocation route, digest format and same-user consistency-only limit; a worker can deliberately forge both list and digest.
  It adds no model judgment, shell question or threshold.
- `bin/fm-jev-guard-claude.ts` normalizes native tool names, forwards actual input and call identity and maps pre-tool refusal to Claude denial; non-pre-tool events return without output.
- `bin/fm-jev-guard-hook.sh` runs the adapter with Bun or Node type stripping and observes its process result so missing or crashed active runtimes require review rather than silently allowing required pre-tool decisions.
  Only successful handler stdout is published; raw failure streams are withheld and the observed exit status is carried in a stable sanitized diagnostic.
- `bin/fm-spawn.sh` remains the launch owner for physical project scope, per-task launch-only guard activation retained on relaunch, context, Claude hook registration, omp extension loading and process-local replace-edit mode.

[`tests/fm-jev-guard.test.sh`](../../tests/fm-jev-guard.test.sh) exercises the public service and adapters with isolated synthetic HTTP fixtures.
[Native verification](../../docs/verification/runtime-backends.md#jev-guard-native-tool-hooks) distinguishes actual host delivery, controlled decision fixtures and deployed acceptance.
