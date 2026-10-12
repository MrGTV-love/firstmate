# Source

This directory holds the level 6 jev-guard from disler's ten-levels-of-jev, vendored from upstream.

- Repository: https://github.com/disler/ten-levels-of-jev
- Path: `apps/ten-levels` (the `LICENSE` file comes from the repository root)
- Commit: `777adaf47d37ae0553220d35b2f15b3a3a063305` (committed 2026-09-27)
- Vendored: 2026-10-07
- License: MIT, see `LICENSE` in this directory.

The upstream paths under `apps/ten-levels` are kept, so every relative import resolves unchanged.

## Unmodified copies

These files are byte-for-byte copies of the upstream files at the same paths:

- `extensions/jev-guard.ts`
- `src/levels/level06/index.ts`, `bash-gate.ts`, `write-gate.ts` and `result-screen.ts`
- `src/core/client.ts`, `helpers.ts`, `mock.ts` and `types.ts`
- `tests/level06.test.ts`
- `LICENSE`

The questions, thresholds, block and banner wording, content trimming, the client's provider snapshot and retries, and the allow-on-error behavior all run as upstream wrote them.
Firstmate supplies shorter client budgets through the upstream constructor options.

## Changed copy: `extensions/report.ts`

Upstream's `report.ts` is the lab's side channel, so it is the one upstream file Firstmate changes.
Each change and its reason:

- `extensions/report.ts`'s `decide` constructs a fresh TypeSafe-only client for each decision, enforcing the 2026-10-09 prohibition on OpenRouter fleet calls instead of retaining the previous provider fallback.
  Unavailable TypeSafe follows upstream's existing no-key error behavior; it never tries another provider.
  The constructor shortens the total request budget; [the operator contract](../../docs/configuration.md#jev-guard) owns current budgets and host limits.
  `seam` reads test endpoint overrides only when `FM_TEST_SEAM=1`.
- `extensions/report.ts`'s `withDecisionBudget` gives each complete handler a shared 25-second cancellation deadline.
  `preflightTimeout` bounds synchronous key and policy preflight to the remaining handler budget.
  `decide` passes the shared cancellation signal to the upstream client so a request cannot outlive its handler.
  omp 18.8.1's supported `extensionHandlers.toolCallTimeoutMs` setting covers only tool calls, not result screening, so Firstmate bounds both paths without extending the host deadline.
- `extensions/report.ts`'s `typesafeKey` reads the key through `bin/fm-typesafe-lib.sh` (`fm_typesafe_key`) for every decision because Firstmate keeps the worker environment free of keys and must honor primary-key rotation and removal.
- `extensions/report.ts`'s `permitted` preflight enforces the captain data-egress decision 2026-10-08, withholding all other, missing or empty project scopes before resolving a credential.
  A withheld request throws, so upstream's own error path allows the tool call while the outside-root write block remains deterministic.
- `extensions/report.ts`'s `permitted` also checks authorized requests against `config/dispatch-never-send` through the existing `fm_typesafe_permitted` policy.
  A worker's explicit no-helper posture withholds judgments before credential lookup while leaving the upstream deterministic safety checks unchanged; [the operator contract](../../docs/configuration.md#jev-guard) owns that behavior.
- `extensions/report.ts`'s `configure` names the owning home, its config and state, the task and project because one shared code root serves many workers.
- `extensions/report.ts`'s `report` sends events to the owning home's private `state/jev-guard.jsonl` instead of the lab's stderr stream, which has no reader in Firstmate.
  The ledger deliberately selects decision metadata, answers and numeric usage, excluding commands, paths, request bodies, questions, reasons, banners, error messages and unknown request-derived fields.
  [The operator contract](../../docs/configuration.md#jev-guard) owns ledger availability and the difference between omp session entries and Claude reporting.
- `extensions/report.ts`'s `decide` records the answering provider in the `jev` event so direct-only routing remains observable.

## Firstmate glue outside this directory

- `bin/fm-jev-guard.ts`'s `installJevGuard` installs the unchanged upstream extension for one worker and wraps both event handlers in the shared decision budget.
  Its `writeRoot` selects the worktree, task-data or temporary root that holds the target, preserving intentional report and scratch writes.
- `bin/fm-jev-guard.ts`'s edit-schema check blocks inputs without a string `path` and `new_string`, telling the agent to report that omp replace edit mode is required.
  omp's default hashline schema differs from pi's, while replace mode matches the unchanged upstream gate without projecting or changing execution arguments.
- `bin/fm-jev-guard.ts`'s path-spelling check enforces the [operator contract](../../docs/configuration.md#jev-guard) for plain file paths and its exact bounded native-device write exceptions.
  Device admission returns before upstream file-root selection and judgment because LSP arguments and job cancellation are not file writes.
  Other spellings block without a Jev call, requiring a plain absolute or worktree-relative path and a report if that is not possible.
  The installer disables shared LSP multiplexing process-locally; the operator contract owns the allowed actions, realpath and snapshot checks, and residual native-server edit and snapshot-to-dispatch risks.
  This allowlist prevents omp's rewritten file spellings from making the unchanged upstream lexical gate judge a different target without reimplementing host resolution or mutating execution arguments.
- `bin/fm-jev-guard-claude.ts:31-48`: Claude has no pi extension API, so the adapter maps Claude's `PreToolUse` and `PostToolUse` payloads to the pi events the upstream handlers read (`file_path` to `path`, `tool_response` to text content).
  `:37` turns an upstream block into a Claude `deny`.
  `:47` delivers the banner as `additionalContext`, because a Claude hook cannot replace a built-in tool's output.
- `bin/fm-jev-guard-hook.sh:15-19`: runs the TypeScript adapter with bun, or node with type stripping, so no build step is needed.
- `bin/fm-spawn.sh`'s `guard_project` setup computes project scope from physical roots and carries it through `j_guard` and `guard_context` to the shared authorization boundary.
  [The operator contract](../../docs/configuration.md#jev-guard) owns the allowed project and withholding behavior.
- `bin/fm-spawn.sh`'s `j_guard` registration and generated `installJevGuard` call install the Claude hooks and omp worker extension without changing primary sessions.
  Its omp launch sets `PI_EDIT_VARIANT=replace` only in ship and scout worker processes, leaving pane and primary settings unchanged.
