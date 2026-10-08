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

- `extensions/report.ts:85-103`: the client calls TypeSafe direct first and asks OpenRouter only when the direct call is unavailable or fails, preserving Firstmate's provider order rather than upstream's single-provider snapshot.
  `:87` and `:89` give each provider a 10-second total budget including retries and response bodies, leaving room inside omp's 30-second handler deadline.
  `:85` reads loopback test endpoints only when `FM_TEST_SEAM=1`.
- `extensions/report.ts:28-46`: `withDecisionBudget` gives each complete handler a shared 25-second cancellation deadline.
  `:62`, `:71` and `:81` bound synchronous key and policy preflight to the remaining handler budget.
  `:94-98` pass the shared cancellation signal through both upstream clients so a fallback cannot outlive its handler.
  omp 18.8.1's supported `extensionHandlers.toolCallTimeoutMs` setting covers only tool calls, not result screening, so Firstmate bounds both paths without extending the host deadline.
- `extensions/report.ts:58-73`: both keys are read through `bin/fm-typesafe-lib.sh` (`fm_typesafe_key`, `fm_openrouter_key`) because Firstmate keeps the worker environment free of keys.
- `extensions/report.ts:26`, `:49-55`, `:77` and `:137`: the captain data-egress decision 2026-10-08 authorizes only the `firstmate` project, so every hook's shared `decide` preflight withholds all other, missing or empty project scopes before either provider is selected.
  A withheld request throws, so upstream's own error path allows the tool call while the outside-root write block remains deterministic.
- `extensions/report.ts:78-83` and `:137`: authorized requests must also pass `config/dispatch-never-send` through the existing `fm_typesafe_permitted` policy.
- `extensions/report.ts:49-55`: `configure` names the owning home, its config and state, the task and project because one shared code root serves many workers.
- `extensions/report.ts:115-121`: events go to the owning home's private `state/jev-guard.jsonl` instead of the lab's stderr stream, which has no reader in Firstmate.
  The ledger deliberately selects decision metadata, answers and numeric usage, excluding commands, paths, request bodies, questions, reasons, banners, error messages and unknown request-derived fields.
  The session entry keeps the full upstream payload.
- `extensions/report.ts:141`: the `jev` event names the answering provider so fallback use is measurable.

## Firstmate glue outside this directory

- `bin/fm-jev-guard.ts:34-58`: installs the unchanged upstream extension for one worker and wraps both event handlers in the shared decision budget.
  `:37-42` selects the worktree, task-data or temporary root that holds the target, preserving intentional report and scratch writes.
- `bin/fm-jev-guard.ts:46-49`: blocks edit inputs without a string `path` and `new_string`, telling the agent to report that omp replace edit mode is required.
  omp's default hashline schema differs from pi's, while replace mode matches the unchanged upstream gate without projecting or changing execution arguments.
- `bin/fm-jev-guard.ts:50-53`: blocks write and edit paths beginning with `~`, `@`, `file:` or `:/` before root selection, requiring a plain absolute or worktree-relative path and a report if that is not possible.
  omp 18.8.1 rewrites those spellings before execution, so rejecting them keeps the unchanged upstream lexical gate from judging a different target without reimplementing host resolution or mutating execution arguments.
- `bin/fm-jev-guard-claude.ts:31-48`: Claude has no pi extension API, so the adapter maps Claude's `PreToolUse` and `PostToolUse` payloads to the pi events the upstream handlers read (`file_path` to `path`, `tool_response` to text content).
  `:37` turns an upstream block into a Claude `deny`.
  `:47` delivers the banner as `additionalContext`, because a Claude hook cannot replace a built-in tool's output.
- `bin/fm-jev-guard-hook.sh:15-19`: runs the TypeScript adapter with bun, or node with type stripping, so no build step is needed.
- `bin/fm-spawn.sh:4763-4771`: computes project scope once from physical roots, using `firstmate` when the project equals the code root, otherwise the project directory basename, and withholding an unresolvable scope.
  `bin/fm-spawn.sh:4792`, `:4939-4941`, `bin/fm-jev-guard-claude.ts:13-15` and `bin/fm-jev-guard.ts:23` carry that scope through both adapters to the shared authorization boundary.
- `bin/fm-spawn.sh:4794`: registers both Claude hooks with a 30-second timeout, matching omp's native deadline and leaving margin around the shared 25-second decision budget.
  `bin/fm-spawn.sh:4955` and `:4964` install the guard in the generated omp worker extension.
  `bin/fm-spawn.sh:4973` sets `PI_EDIT_VARIANT=replace` only in omp ship and scout worker processes next to the generated guard installation, leaving pane and primary settings unchanged.
